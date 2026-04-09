"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.ServersService = void 0;
const common_1 = require("@nestjs/common");
const config_1 = require("@nestjs/config");
const crypto_1 = require("crypto");
const prisma_service_1 = require("../prisma/prisma.service");
const haproxy_service_1 = require("../haproxy/haproxy.service");
let ServersService = class ServersService {
    constructor(prisma, haproxy, config) {
        this.prisma = prisma;
        this.haproxy = haproxy;
        this.config = config;
        this.portMin = this.config.get('FRONTEND_PORT_MIN', 10000);
        this.portMax = this.config.get('FRONTEND_PORT_MAX', 65000);
    }
    async findAll() {
        return this.prisma.server.findMany({ orderBy: { id: 'asc' } });
    }
    async create(dto) {
        const frontendPort = await this.allocatePort();
        const name = 'node_' + (0, crypto_1.randomBytes)(4).toString('hex');
        const server = await this.prisma.server.create({
            data: {
                name,
                ip: dto.ip,
                backendPort: dto.backendPort,
                frontendPort,
            },
        });
        try {
            const allServers = await this.findAll();
            await this.haproxy.applyConfig(allServers);
        }
        catch {
            await this.prisma.server.delete({ where: { id: server.id } });
            throw new common_1.BadRequestException('Failed to apply HAProxy config — server not added');
        }
        return server;
    }
    async remove(id) {
        const server = await this.prisma.server.findUnique({ where: { id } });
        if (!server) {
            throw new common_1.BadRequestException(`Server with id ${id} not found`);
        }
        await this.prisma.server.delete({ where: { id } });
        try {
            const allServers = await this.findAll();
            await this.haproxy.applyConfig(allServers);
        }
        catch {
            await this.prisma.server.create({ data: server });
            throw new common_1.BadRequestException('Failed to apply HAProxy config — server not removed');
        }
    }
    async allocatePort() {
        const usedPorts = await this.prisma.server.findMany({
            select: { frontendPort: true },
        });
        const usedSet = new Set(usedPorts.map((s) => s.frontendPort));
        for (let port = this.portMin; port <= this.portMax; port++) {
            if (!usedSet.has(port)) {
                return port;
            }
        }
        throw new common_1.BadRequestException('No available frontend ports');
    }
};
exports.ServersService = ServersService;
exports.ServersService = ServersService = __decorate([
    (0, common_1.Injectable)(),
    __metadata("design:paramtypes", [prisma_service_1.PrismaService,
        haproxy_service_1.HaproxyService,
        config_1.ConfigService])
], ServersService);
//# sourceMappingURL=servers.service.js.map