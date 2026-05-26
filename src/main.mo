import Result "mo:base/Result";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import HttpTypes "mo:http-types";
import Map "mo:map/Map";

import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import Payments "mo:mcp-motoko-sdk/mcp/Payments";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";

import SrvTypes "mo:mcp-motoko-sdk/server/Types";

import IC "ic:aaaaa-aa";

// Import tool modules
import ToolContext "tools/ToolContext";
import ImageGenerate "tools/image_generate";
import GetGeneration "tools/get_generation";
import ListGenerations "tools/list_generations";
import GetStats "tools/get_stats";

shared ({ caller = deployer }) persistent actor class McpServer(
  args : ?{
    owner : ?Principal;
  }
) = self {

  // The canister owner
  var owner : Principal = Option.get(do ? { args!.owner! }, deployer);

  // State for certified HTTP assets
  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  // Generation storage
  var generationCounter : Nat = 0;
  let generations = Map.new<Text, ToolContext.Generation>();
  let userGenerationIds = Map.new<Principal, [Text]>();

  // Resource contents
  let resourceContents = [
    ("file:///README.md", "# Image Generation MCP Server\nGenerates high-quality images via FLUX 2 Pro + Clarity Upscaler."),
  ];

  let appContext : McpTypes.AppContext = State.init(resourceContents);

  // --- Authentication ---
  let issuerUrl = "https://bfggx-7yaaa-aaaai-q32gq-cai.icp0.io";
  let requiredScopes = ["openid"];

  public query func transformJwksResponse({
    context : Blob;
    response : IC.http_request_result;
  }) : async IC.http_request_result {
    ignore context;
    { response with headers = [] };
  };

  let authContext : ?AuthTypes.AuthContext = ?AuthState.init(
    Principal.fromActor(self),
    owner,
    issuerUrl,
    requiredScopes,
    transformJwksResponse,
  );

  // --- Beacon ---
  let beaconCanisterId = Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai");
  let beaconContext : ?Beacon.BeaconContext = ?Beacon.init(
    beaconCanisterId,
    ?(15 * 60),
  );

  // --- Timers ---
  Cleanup.startCleanupTimer<system>(appContext);

  switch (authContext) {
    case (?ctx) { AuthCleanup.startCleanupTimer<system>(ctx) };
    case (null) { Debug.print("Authentication is disabled.") };
  };

  switch (beaconContext) {
    case (?ctx) { Beacon.startTimer<system>(ctx) };
    case (null) { Debug.print("Beacon is disabled.") };
  };

  // --- Transform function for HTTPS outcalls ---
  public query func transform({
    context : Blob;
    response : IC.http_request_result;
  }) : async IC.http_request_result {
    ignore context;
    { response with headers = [] };
  };

  var falKey : ?Text = null;

  func getFalKey() : ?Text { falKey };

  /// Set the fal.ai API key. Owner-only.
  public shared ({ caller }) func set_fal_key(key : Text) : async () {
    if (caller != owner) { Debug.trap("Only the owner can set the FAL key") };
    falKey := ?key;
  };

  // --- Rate limiting ---
  // 10 generations per 24 hours per user
  let RATE_LIMIT : Nat = 10;
  let RATE_WINDOW : Int = 24 * 60 * 60 * 1_000_000_000; // 24h in nanoseconds
  // Principal -> array of generation timestamps (nanoseconds)
  let rateLimitLog = Map.new<Principal, [Int]>();

  func checkRateLimit(caller : Principal) : ToolContext.RateLimitResult {
    let now = Time.now();
    let windowStart = now - RATE_WINDOW;

    let timestamps = switch (Map.get(rateLimitLog, Map.phash, caller)) {
      case (?ts) { ts };
      case (null) { return { allowed = true; remaining = RATE_LIMIT; resetsIn = 0 } };
    };

    // Filter to only timestamps within the window
    let recent = Array.filter<Int>(timestamps, func(t) { t > windowStart });

    if (recent.size() >= RATE_LIMIT) {
      // Find when the oldest entry in window expires
      let oldest = recent[0];
      let resetsIn = oldest + RATE_WINDOW - now;
      { allowed = false; remaining = 0; resetsIn = resetsIn };
    } else {
      { allowed = true; remaining = RATE_LIMIT - recent.size(); resetsIn = 0 };
    };
  };

  func recordGeneration(caller : Principal) {
    let now = Time.now();
    let windowStart = now - RATE_WINDOW;

    let existing = switch (Map.get(rateLimitLog, Map.phash, caller)) {
      case (?ts) { Array.filter<Int>(ts, func(t) { t > windowStart }) };
      case (null) { [] };
    };

    Map.set(rateLimitLog, Map.phash, caller, Array.append(existing, [now]));
  };

  // --- Helper: store a generation ---
  func storeGeneration(gen : ToolContext.Generation) {
    Map.set(generations, Map.thash, gen.id, gen);
    let existing = switch (Map.get(userGenerationIds, Map.phash, gen.caller)) {
      case (?ids) { ids };
      case (null) { [] };
    };
    Map.set(userGenerationIds, Map.phash, gen.caller, Array.append(existing, [gen.id]));
    generationCounter += 1;
  };

  // --- Helper: get a generation by ID ---
  func getGeneration(id : Text) : ?ToolContext.Generation {
    Map.get(generations, Map.thash, id);
  };

  // --- Helper: list generations for a caller ---
  func listGenerations(caller : Principal, limit : Nat, offset : Nat) : [ToolContext.Generation] {
    let ids = switch (Map.get(userGenerationIds, Map.phash, caller)) {
      case (?ids) { ids };
      case (null) { return [] };
    };

    // Reverse to get newest first
    let reversed = Array.reverse(ids);
    let total = reversed.size();

    if (offset >= total) { return [] };

    let end = Nat.min(offset + limit, total);
    let slice = Iter.toArray(Array.slice(reversed, offset, end));

    Array.mapFilter<Text, ToolContext.Generation>(slice, func(id) {
      Map.get(generations, Map.thash, id);
    });
  };

  // --- Helper: get stats ---
  func getStats() : ToolContext.Stats {
    {
      totalGenerations = generationCounter;
      uniqueUsers = Map.size(userGenerationIds);
    };
  };

  // --- Tool context ---
  transient let toolContext : ToolContext.ToolContext = {
    canisterPrincipal = Principal.fromActor(self);
    owner = owner;
    appContext = appContext;
    getFalKey = getFalKey;
    storeGeneration = storeGeneration;
    getGeneration = getGeneration;
    listGenerations = listGenerations;
    getStats = getStats;
    checkRateLimit = checkRateLimit;
    recordGeneration = recordGeneration;
  };

  // --- Tools ---
  transient let tools : [McpTypes.Tool] = [
    ImageGenerate.config(),
    GetGeneration.config(),
    ListGenerations.config(),
    GetStats.config(),
  ];

  // --- MCP Config ---
  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null;
    serverInfo = {
      name = "image-gen";
      title = "Image Generation";
      version = "0.1.0";
    };
    resources = [
      {
        uri = "file:///README.md";
        name = "README.md";
        title = ?"Documentation";
        description = ?("Image generation MCP server documentation");
        mimeType = ?"text/markdown";
      },
    ];
    resourceReader = func(uri) {
      Map.get(appContext.resourceContents, Map.thash, uri);
    };
    tools = tools;
    toolImplementations = [
      ("image_generate", ImageGenerate.handle(toolContext, transform)),
      ("get_generation", GetGeneration.handle(toolContext)),
      ("list_generations", ListGenerations.handle(toolContext)),
      ("get_stats", GetStats.handle(toolContext)),
    ];
    beacon = beaconContext;
  };

  transient let mcpServer = Mcp.createServer(mcpConfig);

  // --- Public entry points ---
  public query func get_owner() : async Principal { return owner };

  public shared ({ caller }) func set_owner(new_owner : Principal) : async Result.Result<(), Payments.TreasuryError> {
    if (caller != owner) { return #err(#NotOwner) };
    owner := new_owner;
    return #ok(());
  };

  public shared func get_treasury_balance(ledger_id : Principal) : async Nat {
    return await Payments.get_treasury_balance(Principal.fromActor(self), ledger_id);
  };

  public shared ({ caller }) func withdraw(
    ledger_id : Principal,
    amount : Nat,
    destination : Payments.Destination,
  ) : async Result.Result<Nat, Payments.TreasuryError> {
    return await Payments.withdraw(caller, owner, ledger_id, amount, destination);
  };

  // --- HTTP handlers ---
  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      auth = authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) { return mcpResponse };
      case (null) {
        if (req.url == "/") {
          return {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8(
              "<!DOCTYPE html><html><head><title>Image Generation MCP Server</title><style>" #
              "body{font-family:system-ui;max-width:640px;margin:60px auto;padding:0 20px;background:#0a0c1c;color:#e0e0e0}" #
              "h1{color:#fff}a{color:#6cf}code{background:#1a1c2c;padding:2px 6px;border-radius:4px}" #
              "</style></head><body>" #
              "<h1>Image Generation MCP Server</h1>" #
              "<p>Generate high-quality images from text prompts using FLUX 2 Pro with automatic 2x upscaling.</p>" #
              "<p><strong>MCP endpoint:</strong> <code>/mcp</code></p>" #
              "<h3>Tools</h3><ul>" #
              "<li><code>image_generate</code> - Generate an image from a text prompt</li>" #
              "<li><code>get_generation</code> - Retrieve a past generation by ID</li>" #
              "<li><code>list_generations</code> - List your generation history</li>" #
              "<li><code>get_stats</code> - View aggregate statistics</li>" #
              "</ul>" #
              "<p>Total generations: <strong>" # Nat.toText(generationCounter) # "</strong></p>" #
              "</body></html>"
            );
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          return {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    let mcpResponse = await HttpHandler.http_request_update(ctx, req);
    switch (mcpResponse) {
      case (?res) { return res };
      case (null) {
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          upgrade = null;
          streaming_strategy = null;
        };
      };
    };
  };

  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };

  // --- Lifecycle ---
  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  // --- API Key management ---
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    switch (authContext) {
      case (null) { Debug.trap("Authentication is not enabled on this canister.") };
      case (?ctx) { return await ApiKey.create_my_api_key(ctx, msg.caller, name, scopes) };
    };
  };

  public shared (msg) func revoke_my_api_key(key_id : Text) : async () {
    switch (authContext) {
      case (null) { Debug.trap("Authentication is not enabled on this canister.") };
      case (?ctx) { return ApiKey.revoke_my_api_key(ctx, msg.caller, key_id) };
    };
  };

  public query (msg) func list_my_api_keys() : async [AuthTypes.ApiKeyMetadata] {
    switch (authContext) {
      case (null) { Debug.trap("Authentication is not enabled on this canister.") };
      case (?ctx) { return ApiKey.list_my_api_keys(ctx, msg.caller) };
    };
  };

  public type UpgradeFinishedResult = {
    #InProgress : Nat;
    #Failed : (Nat, Text);
    #Success : Nat;
  };
  private func natNow() : Nat { return Int.abs(Time.now()) };
  public func icrc120_upgrade_finished() : async UpgradeFinishedResult {
    #Success(natNow());
  };
};
