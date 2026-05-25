import Principal "mo:base/Principal";
import Result "mo:base/Result";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import Json "mo:json";

module ToolContext {

  /// Context shared between tools and the main canister
  public type ToolContext = {
    canisterPrincipal : Principal;
    owner : Principal;
    appContext : McpTypes.AppContext;
    // Function to get the FAL_KEY at runtime
    getFalKey : () -> ?Text;
    // Function to store a generation record
    storeGeneration : (Generation) -> ();
    // Function to get a generation by ID
    getGeneration : (Text) -> ?Generation;
    // Function to list generations for a caller
    listGenerations : (Principal, Nat, Nat) -> [Generation];
    // Function to get stats
    getStats : () -> Stats;
  };

  public type Generation = {
    id : Text;
    caller : Principal;
    prompt : Text;
    aspectRatio : Text;
    imageUrl : Text;
    seed : ?Nat;
    timestamp : Int;
  };

  public type Stats = {
    totalGenerations : Nat;
    uniqueUsers : Nat;
  };

  /// Helper function to create an error response
  public func makeError(message : Text, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) {
    cb(#ok({ content = [#text({ text = "Error: " # message })]; isError = true; structuredContent = null }));
  };

  /// Helper function to create a success response with structured JSON
  public func makeSuccess(structured : Json.Json, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) {
    cb(#ok({ content = [#text({ text = Json.stringify(structured, null) })]; isError = false; structuredContent = ?structured }));
  };

  /// Helper function to create a success response with plain text
  public func makeTextSuccess(text : Text, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) {
    cb(#ok({ content = [#text({ text = text })]; isError = false; structuredContent = null }));
  };
};
