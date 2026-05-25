import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import Result "mo:base/Result";
import Json "mo:json";
import Int "mo:base/Int";
import Principal "mo:base/Principal";

import ToolContext "ToolContext";

module {

  public func config() : McpTypes.Tool = {
    name = "get_generation";
    title = ?"Get Generation";
    description = ?"Retrieve details of a past image generation by its ID.";
    payment = null;
    inputSchema = Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("generation_id", Json.obj([
          ("type", Json.str("string")),
          ("description", Json.str("The generation ID to look up")),
        ])),
      ])),
      ("required", Json.arr([Json.str("generation_id")])),
    ]);
    outputSchema = ?Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("id", Json.obj([("type", Json.str("string"))])),
        ("prompt", Json.obj([("type", Json.str("string"))])),
        ("aspect_ratio", Json.obj([("type", Json.str("string"))])),
        ("image_url", Json.obj([("type", Json.str("string"))])),
        ("seed", Json.obj([("type", Json.str("number"))])),
        ("timestamp", Json.obj([("type", Json.str("string"))])),
      ])),
    ]);
  };

  public func handle(context : ToolContext.ToolContext) : (
    _args : McpTypes.JsonValue,
    _auth : ?AuthTypes.AuthInfo,
    cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()
  ) -> async () {
    func(args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {

      let caller = switch (auth) {
        case (?a) { a.principal };
        case (null) { Principal.fromText("2vxsx-fae") };
      };

      let genId = switch (Result.toOption(Json.getAsText(args, "generation_id"))) {
        case (?id) { id };
        case (null) {
          return ToolContext.makeError("Missing required 'generation_id' argument", cb);
        };
      };

      switch (context.getGeneration(genId)) {
        case (?gen) {
          // Only allow the caller to see their own generations
          if (Principal.notEqual(gen.caller, caller)) {
            return ToolContext.makeError("Generation not found", cb);
          };

          let seedJson = switch (gen.seed) {
            case (?s) { Json.int(s) };
            case (null) { Json.nullable() };
          };

          let result = Json.obj([
            ("id", Json.str(gen.id)),
            ("prompt", Json.str(gen.prompt)),
            ("aspect_ratio", Json.str(gen.aspectRatio)),
            ("image_url", Json.str(gen.imageUrl)),
            ("seed", seedJson),
            ("timestamp", Json.str(Int.toText(gen.timestamp))),
          ]);

          ToolContext.makeSuccess(result, cb);
        };
        case (null) {
          ToolContext.makeError("Generation not found", cb);
        };
      };
    };
  };
};
