import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import Result "mo:base/Result";
import Json "mo:json";

import ToolContext "ToolContext";

module {

  public func config() : McpTypes.Tool = {
    name = "get_stats";
    title = ?"Generation Stats";
    description = ?"Get aggregate image generation statistics. No authentication required.";
    payment = null;
    inputSchema = Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([])),
    ]);
    outputSchema = ?Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("total_generations", Json.obj([("type", Json.str("number"))])),
        ("unique_users", Json.obj([("type", Json.str("number"))])),
      ])),
    ]);
  };

  public func handle(context : ToolContext.ToolContext) : (
    _args : McpTypes.JsonValue,
    _auth : ?AuthTypes.AuthInfo,
    cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()
  ) -> async () {
    func(_args : McpTypes.JsonValue, _auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
      let stats = context.getStats();

      let result = Json.obj([
        ("total_generations", Json.int(stats.totalGenerations)),
        ("unique_users", Json.int(stats.uniqueUsers)),
      ]);

      ToolContext.makeSuccess(result, cb);
    };
  };
};
