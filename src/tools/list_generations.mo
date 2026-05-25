import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";
import Result "mo:base/Result";
import Json "mo:json";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Iter "mo:base/Iter";

import ToolContext "ToolContext";

module {

  public func config() : McpTypes.Tool = {
    name = "list_generations";
    title = ?"List Generations";
    description = ?"List your recent image generations with pagination.";
    payment = null;
    inputSchema = Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("limit", Json.obj([
          ("type", Json.str("number")),
          ("description", Json.str("Max results to return (default: 20, max: 100)")),
        ])),
        ("offset", Json.obj([
          ("type", Json.str("number")),
          ("description", Json.str("Number of results to skip (default: 0)")),
        ])),
      ])),
    ]);
    outputSchema = ?Json.obj([
      ("type", Json.str("object")),
      ("properties", Json.obj([
        ("generations", Json.obj([
          ("type", Json.str("array")),
          ("items", Json.obj([("type", Json.str("object"))])),
        ])),
        ("total", Json.obj([("type", Json.str("number"))])),
        ("limit", Json.obj([("type", Json.str("number"))])),
        ("offset", Json.obj([("type", Json.str("number"))])),
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

      // Parse limit (default 20, max 100)
      let limit = switch (Result.toOption(Json.getAsNat(args, "limit"))) {
        case (?n) { if (n > 100) { 100 } else { n } };
        case (null) { 20 };
      };

      // Parse offset (default 0)
      let offset = switch (Result.toOption(Json.getAsNat(args, "offset"))) {
        case (?n) { n };
        case (null) { 0 };
      };

      let generations = context.listGenerations(caller, limit, offset);

      let genJsons = Array.map<ToolContext.Generation, Json.Json>(generations, func(gen) {
        let seedJson = switch (gen.seed) {
          case (?s) { Json.int(s) };
          case (null) { Json.nullable() };
        };

        Json.obj([
          ("id", Json.str(gen.id)),
          ("prompt", Json.str(
            if (gen.prompt.size() > 80) {
              Text.trimEnd(Text.trimEnd(Text.fromIter(gen.prompt.chars()), #char ' '), #char ' ') # "..."
            } else { gen.prompt }
          )),
          ("aspect_ratio", Json.str(gen.aspectRatio)),
          ("image_url", Json.str(gen.imageUrl)),
          ("seed", seedJson),
          ("timestamp", Json.str(Int.toText(gen.timestamp))),
        ]);
      });

      let result = Json.obj([
        ("generations", Json.arr(genJsons)),
        ("total", Json.int(generations.size())),
        ("limit", Json.int(limit)),
        ("offset", Json.int(offset)),
      ]);

      ToolContext.makeSuccess(result, cb);
    };
  };
};
