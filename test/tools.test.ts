/**
 * Tool-Specific Test Suite for Image Generation MCP Server
 */

import { describe, beforeAll, afterAll, it, expect, inject } from 'vitest';
import { PocketIc, createIdentity } from '@dfinity/pic';
import { IDL } from '@icp-sdk/core/candid';
import { idlFactory as mcpServerIdlFactory } from '../.dfx/local/canisters/image_gen/service.did.js';
import type { _SERVICE as McpServerService } from '../.dfx/local/canisters/image_gen/service.did.d.ts';
import type { Actor } from '@dfinity/pic';
import path from 'node:path';

const MCP_SERVER_WASM_PATH = path.resolve(
  __dirname,
  '../.dfx/local/canisters/image_gen/image_gen.wasm',
);

function makeRpcCall(method: string, params: any, id: string = 'test') {
  return new TextEncoder().encode(JSON.stringify({
    jsonrpc: '2.0',
    method,
    params,
    id,
  }));
}

function parseResponse(httpResponse: any) {
  return JSON.parse(
    new TextDecoder().decode(httpResponse.body as Uint8Array),
  );
}

describe('Image Generation Tool Tests', () => {
  let pic: PocketIc;
  let serverActor: Actor<McpServerService>;
  let canisterId: any;
  let testOwner = createIdentity('test-owner');
  let apiKey: string;

  beforeAll(async () => {
    const picUrl = inject('PIC_URL');
    pic = await PocketIc.create(picUrl);
    canisterId = await pic.createCanister();

    const initArg = IDL.encode(
      [IDL.Opt(IDL.Record({ owner: IDL.Opt(IDL.Principal) }))],
      [[{ owner: [testOwner.getPrincipal()] }]],
    );

    await pic.installCode({
      canisterId,
      wasm: MCP_SERVER_WASM_PATH,
      arg: initArg.buffer as ArrayBufferLike,
    });

    serverActor = pic.createActor<McpServerService>(
      mcpServerIdlFactory,
      canisterId,
    );

    // Create API key for authenticated requests
    serverActor.setIdentity(testOwner);
    apiKey = await (serverActor as any).create_my_api_key('test-key', ['openid']);
  });

  afterAll(async () => {
    await pic?.tearDown();
  });

  function makeAuthHeaders(): [string, string][] {
    return [
      ['Content-Type', 'application/json'],
      ['X-API-Key', apiKey],
    ];
  }

  describe('tools/list', () => {
    it('should list all 4 tools', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/list', {}, 'list-tools'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.tools).toBeDefined();
      expect(Array.isArray(response.result.tools)).toBe(true);

      const toolNames = response.result.tools.map((t: any) => t.name);
      expect(toolNames).toContain('image_generate');
      expect(toolNames).toContain('get_generation');
      expect(toolNames).toContain('list_generations');
      expect(toolNames).toContain('get_stats');
      expect(response.result.tools.length).toBe(4);
    });

    it('should have proper schemas for image_generate', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/list', {}, 'schema-check'),
        certificate_version: [],
      });

      const response = parseResponse(httpResponse);
      const imgTool = response.result.tools.find((t: any) => t.name === 'image_generate');

      expect(imgTool).toBeDefined();
      expect(imgTool.description).toContain('FLUX 2 Pro');
      expect(imgTool.inputSchema.properties.prompt).toBeDefined();
      expect(imgTool.inputSchema.properties.aspect_ratio).toBeDefined();
      expect(imgTool.inputSchema.properties.aspect_ratio.enum).toEqual(['landscape', 'square', 'portrait']);
      expect(imgTool.inputSchema.required).toEqual(['prompt']);
    });
  });

  describe('get_stats tool', () => {
    it('should return stats', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', { name: 'get_stats', arguments: {} }, 'stats'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(false);

      const result = JSON.parse(response.result.content[0].text);
      expect(result.total_generations).toBe(0);
      expect(result.unique_users).toBe(0);
    });
  });

  describe('image_generate tool', () => {
    it('should fail without FAL_KEY configured', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'image_generate',
          arguments: { prompt: 'a sunset over mountains' },
        }, 'gen-no-key'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(true);
      expect(response.result.content[0].text).toContain('FAL_KEY');
    });

    it('should fail with missing prompt', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'image_generate',
          arguments: {},
        }, 'gen-no-prompt'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(true);
      expect(response.result.content[0].text).toContain('prompt');
    });

    it('should fail with invalid aspect_ratio', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'image_generate',
          arguments: { prompt: 'test', aspect_ratio: 'widescreen' },
        }, 'gen-bad-ar'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(true);
      expect(response.result.content[0].text).toContain('aspect_ratio');
    });
  });

  describe('get_generation tool', () => {
    it('should return not found for nonexistent generation', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'get_generation',
          arguments: { generation_id: 'nonexistent-123' },
        }, 'get-gen-notfound'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(true);
      expect(response.result.content[0].text).toContain('not found');
    });

    it('should fail with missing generation_id', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'get_generation',
          arguments: {},
        }, 'get-gen-missing'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(true);
      expect(response.result.content[0].text).toContain('generation_id');
    });
  });

  describe('list_generations tool', () => {
    it('should return empty list for new user', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'list_generations',
          arguments: {},
        }, 'list-gen-empty'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(false);

      const result = JSON.parse(response.result.content[0].text);
      expect(result.generations).toEqual([]);
      expect(result.total).toBe(0);
      expect(result.limit).toBe(20);
      expect(result.offset).toBe(0);
    });

    it('should respect limit and offset params', async () => {
      serverActor.setIdentity(testOwner);

      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', {
          name: 'list_generations',
          arguments: { limit: 5, offset: 10 },
        }, 'list-gen-paged'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(false);

      const result = JSON.parse(response.result.content[0].text);
      expect(result.limit).toBe(5);
      expect(result.offset).toBe(10);
    });
  });

  describe('set_fal_key', () => {
    it('should only allow owner to set key', async () => {
      const nonOwner = createIdentity('non-owner');
      serverActor.setIdentity(nonOwner);

      await expect(
        (serverActor as any).set_fal_key('fake-key')
      ).rejects.toThrow();
    });

    it('should allow owner to set key', async () => {
      serverActor.setIdentity(testOwner);

      // Should not throw
      await (serverActor as any).set_fal_key('test-fal-key-123');

      // Verify the key is set by checking get_stats still works
      // (We can't test image_generate with a real key in PocketIC since
      // HTTPS outcalls aren't supported, but we verified the setter works)
      const httpResponse = await serverActor.http_request_update({
        method: 'POST',
        url: '/mcp',
        headers: makeAuthHeaders(),
        body: makeRpcCall('tools/call', { name: 'get_stats', arguments: {} }, 'post-key-stats'),
        certificate_version: [],
      });

      expect(httpResponse.status_code).toBe(200);
      const response = parseResponse(httpResponse);
      expect(response.result.isError).toBe(false);
    });
  });
});
