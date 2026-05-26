import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import Result "mo:base/Result";
import Json "mo:json";
import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Blob "mo:base/Blob";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Debug "mo:base/Debug";
import Error "mo:base/Error";

import ToolContext "ToolContext";
import IC "ic:aaaaa-aa";

module {

  public func config() : McpTypes.Tool = {
    name = "image_generate";
    title = ?"Image Generator";
    description = ?"Generate a high-quality image from a text prompt using FLUX 2 Pro with automatic 2x upscaling. Returns an image URL.";
    payment = null;
    inputSchema = Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("prompt", Json.obj([
          ("type", Json.str("string")),
          ("description", Json.str("Detailed text prompt describing the desired image. Be specific about subject, style, lighting, composition.")),
        ])),
        ("aspect_ratio", Json.obj([
          ("type", Json.str("string")),
          ("enum", Json.arr([Json.str("landscape"), Json.str("square"), Json.str("portrait")])),
          ("description", Json.str("Aspect ratio: 'landscape' (wide 16:9), 'square' (1:1), 'portrait' (tall 16:9). Default: landscape.")),
        ])),
      ])),
      ("required", Json.arr([Json.str("prompt")])),
    ]);
    outputSchema = ?Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("image_url", Json.obj([("type", Json.str("string")), ("description", Json.str("URL of the generated image"))])),
        ("prompt", Json.obj([("type", Json.str("string"))])),
        ("aspect_ratio", Json.obj([("type", Json.str("string"))])),
        ("seed", Json.obj([("type", Json.str("number"))])),
        ("generation_id", Json.obj([("type", Json.str("string"))])),
      ])),
      ("required", Json.arr([Json.str("image_url"), Json.str("generation_id")])),
    ]);
  };

  // Map aspect_ratio to fal.ai image_size enum
  func mapAspectRatio(ar : Text) : Text {
    switch (ar) {
      case ("square") { "square_hd" };
      case ("portrait") { "portrait_16_9" };
      case _ { "landscape_16_9" }; // default
    };
  };

  public func handle(context : ToolContext.ToolContext, transform : shared query ({ context : Blob; response : IC.http_request_result }) -> async IC.http_request_result) : (
    _args : McpTypes.JsonValue,
    _auth : ?AuthTypes.AuthInfo,
    cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()
  ) -> async () {
    func(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {

      // Get caller principal
      let caller = switch (auth) {
        case (?a) { a.principal };
        case (null) { Principal.fromText("2vxsx-fae") };
      };

      // Check rate limit (10 per 24h per user)
      let rateLimit = context.checkRateLimit(caller);
      if (not rateLimit.allowed) {
        let hoursLeft = Int.abs(rateLimit.resetsIn) / (3_600_000_000_000);
        return ToolContext.makeError("Rate limit exceeded. You can generate 10 images per 24 hours. Try again in ~" # Nat.toText(hoursLeft) # " hours.", cb);
      };

      // Parse prompt
      let prompt = switch (Result.toOption(Json.getAsText(args, "prompt"))) {
        case (?p) { p };
        case (null) {
          return ToolContext.makeError("Missing required 'prompt' argument", cb);
        };
      };

      // Parse aspect_ratio (default: landscape)
      let aspectRatio = switch (Result.toOption(Json.getAsText(args, "aspect_ratio"))) {
        case (?ar) {
          if (ar == "landscape" or ar == "square" or ar == "portrait") { ar }
          else { return ToolContext.makeError("Invalid aspect_ratio. Must be 'landscape', 'square', or 'portrait'.", cb) };
        };
        case (null) { "landscape" };
      };

      // Get FAL_KEY
      let falKey = switch (context.getFalKey()) {
        case (?k) { k };
        case (null) {
          return ToolContext.makeError("Image generation not configured — FAL_KEY env var required", cb);
        };
      };

      let imageSize = mapAspectRatio(aspectRatio);

      // Step 1: Generate image via flux-2-pro
      let genPayload = "{\"prompt\":\"" # escapeJson(prompt) # "\",\"image_size\":\"" # imageSize # "\",\"output_format\":\"jpeg\",\"safety_tolerance\":\"2\"}";

      let genRequest : IC.http_request_args = {
        url = "https://fal.run/fal-ai/flux-2-pro";
        max_response_bytes = ?(50_000 : Nat64);
        headers = [
          { name = "Authorization"; value = "Key " # falKey },
          { name = "Content-Type"; value = "application/json" },
        ];
        body = ?Text.encodeUtf8(genPayload);
        method = #post;
        transform = ?{
          function = transform;
          context = Blob.fromArray([]);
        };
        is_replicated = ?false;
      };

      let genResponse = try {
        await (with cycles = 300_000_000_000) IC.http_request(genRequest);
      } catch (e) {
        return ToolContext.makeError("Failed to call fal.ai: " # Error.message(e), cb);
      };

      if (genResponse.status != 200) {
        let errBody = switch (Text.decodeUtf8(genResponse.body)) {
          case (?t) { t };
          case (null) { "Unknown error" };
        };
        return ToolContext.makeError("fal.ai returned status " # Nat.toText(genResponse.status) # ": " # errBody, cb);
      };

      let genBodyText = switch (Text.decodeUtf8(genResponse.body)) {
        case (?t) { t };
        case (null) {
          return ToolContext.makeError("Invalid UTF-8 response from fal.ai", cb);
        };
      };

      // Parse the generation response to get image URL and seed
      let genJson = switch (Json.parse(genBodyText)) {
        case (#ok(j)) { j };
        case (#err(_)) {
          return ToolContext.makeError("Failed to parse fal.ai response JSON", cb);
        };
      };

      let imageUrl = switch (extractImageUrl(genJson)) {
        case (?url) { url };
        case (null) {
          return ToolContext.makeError("No image URL in fal.ai response", cb);
        };
      };

      let seed = extractSeed(genJson);

      // Step 2: Upscale via clarity-upscaler
      let upscalePayload = "{\"image_url\":\"" # escapeJson(imageUrl) # "\",\"upscale_factor\":2,\"creativity\":0.35,\"resemblance\":0.6,\"guidance_scale\":4,\"num_inference_steps\":18}";

      let upscaleRequest : IC.http_request_args = {
        url = "https://fal.run/fal-ai/clarity-upscaler";
        max_response_bytes = ?(50_000 : Nat64);
        headers = [
          { name = "Authorization"; value = "Key " # falKey },
          { name = "Content-Type"; value = "application/json" },
        ];
        body = ?Text.encodeUtf8(upscalePayload);
        method = #post;
        transform = ?{
          function = transform;
          context = Blob.fromArray([]);
        };
        is_replicated = ?false;
      };

      // Upscale is best-effort — if it fails, return original image
      let finalImageUrl = try {
        let upscaleResponse = await (with cycles = 300_000_000_000) IC.http_request(upscaleRequest);
        if (upscaleResponse.status == 200) {
          switch (Text.decodeUtf8(upscaleResponse.body)) {
            case (?t) {
              switch (Json.parse(t)) {
                case (#ok(j)) {
                  switch (extractUpscaledImageUrl(j)) {
                    case (?url) { url };
                    case (null) { imageUrl }; // fallback
                  };
                };
                case (#err(_)) { imageUrl };
              };
            };
            case (null) { imageUrl };
          };
        } else {
          imageUrl // fallback to original
        };
      } catch (_e) {
        imageUrl // fallback to original on any error
      };

      // Store generation record
      let genId = Nat.toText(Int.abs(Time.now()));
      let generation : ToolContext.Generation = {
        id = genId;
        caller = caller;
        prompt = prompt;
        aspectRatio = aspectRatio;
        imageUrl = finalImageUrl;
        seed = seed;
        timestamp = Time.now();
      };
      context.storeGeneration(generation);
      context.recordGeneration(caller);

      // Build response
      let seedJson = switch (seed) {
        case (?s) { Json.int(s) };
        case (null) { Json.nullable() };
      };

      let result = Json.obj([
        ("image_url", Json.str(finalImageUrl)),
        ("prompt", Json.str(prompt)),
        ("aspect_ratio", Json.str(aspectRatio)),
        ("seed", seedJson),
        ("generation_id", Json.str(genId)),
      ]);

      ToolContext.makeSuccess(result, cb);
    };
  };

  // Extract images[0].url from fal.ai flux-2-pro response
  func extractImageUrl(json : Json.Json) : ?Text {
    Result.toOption(Json.getAsText(json, "images[0].url"));
  };

  // Extract image.url from clarity-upscaler response
  func extractUpscaledImageUrl(json : Json.Json) : ?Text {
    Result.toOption(Json.getAsText(json, "image.url"));
  };

  // Extract seed from response
  func extractSeed(json : Json.Json) : ?Nat {
    Result.toOption(Json.getAsNat(json, "seed"));
  };

  // Simple JSON string escaping
  func escapeJson(text : Text) : Text {
    var result = "";
    for (c in text.chars()) {
      if (c == '\"') { result #= "\\\"" }
      else if (c == '\\') { result #= "\\\\" }
      else { result #= Text.fromChar(c) };
    };
    result;
  };
};
