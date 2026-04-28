{
  "errorMessage": "Bad request - please check your parameters",
  "errorDescription": "new row for relation \"variantes\" violates check constraint \"variantes_estado_check\"",
  "errorDetails": {
    "rawErrorMessage": [
      "400 - \"{\\\"code\\\":\\\"23514\\\",\\\"details\\\":\\\"Failing row contains (74f438f7-413c-48a6-a34a-13ec6698f222, 8031aec4-2380-4cd4-b7ff-bf927bf4197c, 52339422232894, 9689832751422, AA-SER5111, Lila, Lila, null, 100000.00, 230000.00, null, 100.00, 400.00, null, draft, 2026-02-22 17:17:16+00, 2026-04-02 17:43:40.023518+00, 2026-04-02 17:43:40.023518+00, 54345023750462).\\\",\\\"hint\\\":null,\\\"message\\\":\\\"new row for relation \\\\\\\"variantes\\\\\\\" violates check constraint \\\\\\\"variantes_estado_check\\\\\\\"\\\"}\""
    ],
    "httpCode": "400"
  },
  "n8nDetails": {
    "nodeName": "Call backfill_products RPC",
    "nodeType": "n8n-nodes-base.httpRequest",
    "nodeVersion": 4.4,
    "itemIndex": 0,
    "time": "4/2/2026, 12:43:40 PM",
    "n8nVersion": "2.13.3 (Cloud)",
    "binaryDataMode": "filesystem",
    "stackTrace": [
      "NodeApiError: Bad request - please check your parameters",
      "    at ExecuteContext.execute (/usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-nodes-base@file+packages+nodes-base_@aws-sdk+credential-providers@3.808.0_asn1.js@5_8da18263ca0574b0db58d4fefd8173ce/node_modules/n8n-nodes-base/nodes/HttpRequest/V3/HttpRequestV3.node.ts:809:16)",
      "    at WorkflowExecute.executeNode (/usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-core@file+packages+core_@opentelemetry+api@1.9.0_@opentelemetry+exporter-trace-otlp_9f358c3eeaef0d2736f54ac9757ada43/node_modules/n8n-core/src/execution-engine/workflow-execute.ts:1043:8)",
      "    at WorkflowExecute.runNode (/usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-core@file+packages+core_@opentelemetry+api@1.9.0_@opentelemetry+exporter-trace-otlp_9f358c3eeaef0d2736f54ac9757ada43/node_modules/n8n-core/src/execution-engine/workflow-execute.ts:1222:11)",
      "    at /usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-core@file+packages+core_@opentelemetry+api@1.9.0_@opentelemetry+exporter-trace-otlp_9f358c3eeaef0d2736f54ac9757ada43/node_modules/n8n-core/src/execution-engine/workflow-execute.ts:1668:27",
      "    at /usr/local/lib/node_modules/n8n/node_modules/.pnpm/n8n-core@file+packages+core_@opentelemetry+api@1.9.0_@opentelemetry+exporter-trace-otlp_9f358c3eeaef0d2736f54ac9757ada43/node_modules/n8n-core/src/execution-engine/workflow-execute.ts:2313:11"
    ]
  }
}