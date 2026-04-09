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
var HaproxyService_1;
Object.defineProperty(exports, "__esModule", { value: true });
exports.HaproxyService = void 0;
const common_1 = require("@nestjs/common");
const config_1 = require("@nestjs/config");
const child_process_1 = require("child_process");
const promises_1 = require("fs/promises");
const util_1 = require("util");
const execAsync = (0, util_1.promisify)(child_process_1.exec);
let HaproxyService = HaproxyService_1 = class HaproxyService {
    constructor(config) {
        this.config = config;
        this.logger = new common_1.Logger(HaproxyService_1.name);
        this.configPath = this.config.get('HAPROXY_CONFIG_PATH');
    }
    buildConfig(servers) {
        const lines = [
            'global',
            '    log /dev/log local0',
            '    maxconn 50000',
            '    daemon',
            '',
            'defaults',
            '    log global',
            '    mode tcp',
            '    timeout connect 5s',
            '    timeout client  1h',
            '    timeout server  1h',
            '    timeout tunnel  1h',
            '    timeout client-fin 30s',
            '    timeout server-fin 30s',
        ];
        for (const server of servers) {
            lines.push('', `frontend ${server.name}_in`, `    bind *:${server.frontendPort}`, '    mode tcp', '    tcp-request inspect-delay 5s', '    tcp-request content accept if { req.ssl_hello_type 1 }', `    default_backend ${server.name}`);
        }
        for (const server of servers) {
            lines.push('', `backend ${server.name}`, '    mode tcp', `    server s_${server.id} ${server.ip}:${server.backendPort} check inter 30s fall 3 rise 2`);
        }
        return lines.join('\n') + '\n';
    }
    async applyConfig(servers) {
        let backup = null;
        try {
            backup = await (0, promises_1.readFile)(this.configPath, 'utf-8').catch(() => null);
        }
        catch {
        }
        const newConfig = this.buildConfig(servers);
        await (0, promises_1.writeFile)(this.configPath, newConfig, 'utf-8');
        try {
            await execAsync('haproxy -c -f ' + this.configPath);
            await execAsync('systemctl reload haproxy');
            this.logger.log('HAProxy config applied and reloaded');
        }
        catch (error) {
            this.logger.error('HAProxy reload failed, rolling back', error);
            if (backup !== null) {
                await (0, promises_1.writeFile)(this.configPath, backup, 'utf-8');
                await execAsync('systemctl reload haproxy').catch(() => { });
            }
            throw error;
        }
    }
};
exports.HaproxyService = HaproxyService;
exports.HaproxyService = HaproxyService = HaproxyService_1 = __decorate([
    (0, common_1.Injectable)(),
    __metadata("design:paramtypes", [config_1.ConfigService])
], HaproxyService);
//# sourceMappingURL=haproxy.service.js.map