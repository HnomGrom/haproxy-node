"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.getPrismaClientClass = getPrismaClientClass;
const runtime = require("@prisma/client/runtime/client");
const config = {
    "previewFeatures": [],
    "clientVersion": "7.7.0",
    "engineVersion": "75cbdc1eb7150937890ad5465d861175c6624711",
    "activeProvider": "sqlite",
    "inlineSchema": "generator client {\n  provider = \"prisma-client\"\n  output   = \"../generated/prisma\"\n}\n\ndatasource db {\n  provider = \"sqlite\"\n}\n\nmodel Server {\n  id           Int      @id @default(autoincrement())\n  name         String   @unique\n  ip           String\n  backendPort  Int\n  frontendPort Int      @unique\n  createdAt    DateTime @default(now())\n}\n",
    "runtimeDataModel": {
        "models": {},
        "enums": {},
        "types": {}
    },
    "parameterizationSchema": {
        "strings": [],
        "graph": ""
    }
};
config.runtimeDataModel = JSON.parse("{\"models\":{\"Server\":{\"fields\":[{\"name\":\"id\",\"kind\":\"scalar\",\"type\":\"Int\"},{\"name\":\"name\",\"kind\":\"scalar\",\"type\":\"String\"},{\"name\":\"ip\",\"kind\":\"scalar\",\"type\":\"String\"},{\"name\":\"backendPort\",\"kind\":\"scalar\",\"type\":\"Int\"},{\"name\":\"frontendPort\",\"kind\":\"scalar\",\"type\":\"Int\"},{\"name\":\"createdAt\",\"kind\":\"scalar\",\"type\":\"DateTime\"}],\"dbName\":null}},\"enums\":{},\"types\":{}}");
config.parameterizationSchema = {
    strings: JSON.parse("[\"where\",\"Server.findUnique\",\"Server.findUniqueOrThrow\",\"orderBy\",\"cursor\",\"Server.findFirst\",\"Server.findFirstOrThrow\",\"Server.findMany\",\"data\",\"Server.createOne\",\"Server.createMany\",\"Server.createManyAndReturn\",\"Server.updateOne\",\"Server.updateMany\",\"Server.updateManyAndReturn\",\"create\",\"update\",\"Server.upsertOne\",\"Server.deleteOne\",\"Server.deleteMany\",\"having\",\"_count\",\"_avg\",\"_sum\",\"_min\",\"_max\",\"Server.groupBy\",\"Server.aggregate\",\"AND\",\"OR\",\"NOT\",\"id\",\"name\",\"ip\",\"backendPort\",\"frontendPort\",\"createdAt\",\"equals\",\"in\",\"notIn\",\"lt\",\"lte\",\"gt\",\"gte\",\"not\",\"contains\",\"startsWith\",\"endsWith\",\"set\",\"increment\",\"decrement\",\"multiply\",\"divide\"]"),
    graph: "MAsQCRwAACUAMB0AAAQAEB4AACUAMB8CAAAAASABAAAAASEBACcAISICACYAISMCAAAAASRAACgAIQEAAAABACABAAAAAQAgCRwAACUAMB0AAAQAEB4AACUAMB8CACYAISABACcAISEBACcAISICACYAISMCACYAISRAACgAIQADAAAABAAgAwAABQAwBAAAAQAgAwAAAAQAIAMAAAUAMAQAAAEAIAMAAAAEACADAAAFADAEAAABACAGHwIAAAABIAEAAAABIQEAAAABIgIAAAABIwIAAAABJEAAAAABAQgAAAkAIAYfAgAAAAEgAQAAAAEhAQAAAAEiAgAAAAEjAgAAAAEkQAAAAAEBCAAACwAwAQgAAAsAMAYfAgAvACEgAQAuACEhAQAuACEiAgAvACEjAgAvACEkQAAwACECAAAAAQAgCAAADgAgBh8CAC8AISABAC4AISEBAC4AISICAC8AISMCAC8AISRAADAAIQIAAAAEACAIAAAQACACAAAABAAgCAAAEAAgAwAAAAEAIA8AAAkAIBAAAA4AIAEAAAABACABAAAABAAgBRUAACkAIBYAACoAIBcAAC0AIBgAACwAIBkAACsAIAkcAAAaADAdAAAXABAeAAAaADAfAgAbACEgAQAcACEhAQAcACEiAgAbACEjAgAbACEkQAAdACEDAAAABAAgAwAAFgAwFAAAFwAgAwAAAAQAIAMAAAUAMAQAAAEAIAkcAAAaADAdAAAXABAeAAAaADAfAgAbACEgAQAcACEhAQAcACEiAgAbACEjAgAbACEkQAAdACENFQAAHwAgFgAAJAAgFwAAHwAgGAAAHwAgGQAAHwAgJQIAAAABJgIAAAAEJwIAAAAEKAIAAAABKQIAAAABKgIAAAABKwIAAAABLAIAIwAhDhUAAB8AIBgAACIAIBkAACIAICUBAAAAASYBAAAABCcBAAAABCgBAAAAASkBAAAAASoBAAAAASsBAAAAASwBACEAIS0BAAAAAS4BAAAAAS8BAAAAAQsVAAAfACAYAAAgACAZAAAgACAlQAAAAAEmQAAAAAQnQAAAAAQoQAAAAAEpQAAAAAEqQAAAAAErQAAAAAEsQAAeACELFQAAHwAgGAAAIAAgGQAAIAAgJUAAAAABJkAAAAAEJ0AAAAAEKEAAAAABKUAAAAABKkAAAAABK0AAAAABLEAAHgAhCCUCAAAAASYCAAAABCcCAAAABCgCAAAAASkCAAAAASoCAAAAASsCAAAAASwCAB8AIQglQAAAAAEmQAAAAAQnQAAAAAQoQAAAAAEpQAAAAAEqQAAAAAErQAAAAAEsQAAgACEOFQAAHwAgGAAAIgAgGQAAIgAgJQEAAAABJgEAAAAEJwEAAAAEKAEAAAABKQEAAAABKgEAAAABKwEAAAABLAEAIQAhLQEAAAABLgEAAAABLwEAAAABCyUBAAAAASYBAAAABCcBAAAABCgBAAAAASkBAAAAASoBAAAAASsBAAAAASwBACIAIS0BAAAAAS4BAAAAAS8BAAAAAQ0VAAAfACAWAAAkACAXAAAfACAYAAAfACAZAAAfACAlAgAAAAEmAgAAAAQnAgAAAAQoAgAAAAEpAgAAAAEqAgAAAAErAgAAAAEsAgAjACEIJQgAAAABJggAAAAEJwgAAAAEKAgAAAABKQgAAAABKggAAAABKwgAAAABLAgAJAAhCRwAACUAMB0AAAQAEB4AACUAMB8CACYAISABACcAISEBACcAISICACYAISMCACYAISRAACgAIQglAgAAAAEmAgAAAAQnAgAAAAQoAgAAAAEpAgAAAAEqAgAAAAErAgAAAAEsAgAfACELJQEAAAABJgEAAAAEJwEAAAAEKAEAAAABKQEAAAABKgEAAAABKwEAAAABLAEAIgAhLQEAAAABLgEAAAABLwEAAAABCCVAAAAAASZAAAAABCdAAAAABChAAAAAASlAAAAAASpAAAAAAStAAAAAASxAACAAIQAAAAAAATABAAAAAQUwAgAAAAExAgAAAAEyAgAAAAEzAgAAAAE0AgAAAAEBMEAAAAABAAAAAAUVAAYWAAcXAAgYAAkZAAoAAAAAAAUVAAYWAAcXAAgYAAkZAAoBAgECAwEFBgEGBwEHCAEJCgEKDAILDQMMDwENEQIOEgQREwESFAETFQIaGAUbGQs"
};
async function decodeBase64AsWasm(wasmBase64) {
    const { Buffer } = await Promise.resolve().then(() => require('node:buffer'));
    const wasmArray = Buffer.from(wasmBase64, 'base64');
    return new WebAssembly.Module(wasmArray);
}
config.compilerWasm = {
    getRuntime: async () => await Promise.resolve().then(() => require("@prisma/client/runtime/query_compiler_fast_bg.sqlite.js")),
    getQueryCompilerWasmModule: async () => {
        const { wasm } = await Promise.resolve().then(() => require("@prisma/client/runtime/query_compiler_fast_bg.sqlite.wasm-base64.js"));
        return await decodeBase64AsWasm(wasm);
    },
    importName: "./query_compiler_fast_bg.js"
};
function getPrismaClientClass() {
    return runtime.getPrismaClient(config);
}
//# sourceMappingURL=class.js.map