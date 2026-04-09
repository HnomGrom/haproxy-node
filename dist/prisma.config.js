"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
require("dotenv/config");
const path_1 = require("path");
const config_1 = require("prisma/config");
exports.default = (0, config_1.defineConfig)({
    schema: path_1.default.join(__dirname, "prisma", "schema.prisma"),
    migrations: {
        path: path_1.default.join(__dirname, "prisma", "migrations"),
    },
    datasource: {
        url: process.env["DATABASE_URL"],
    },
});
//# sourceMappingURL=prisma.config.js.map