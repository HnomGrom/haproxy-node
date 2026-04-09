import { ConfigService } from '@nestjs/config';
import { Server } from '../../generated/prisma/client';
export declare class HaproxyService {
    private readonly config;
    private readonly logger;
    private readonly configPath;
    constructor(config: ConfigService);
    buildConfig(servers: Server[]): string;
    applyConfig(servers: Server[]): Promise<void>;
}
