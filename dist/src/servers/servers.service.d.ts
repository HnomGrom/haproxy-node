import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../prisma/prisma.service';
import { HaproxyService } from '../haproxy/haproxy.service';
import { CreateServerDto } from './dto/create-server.dto';
import { Server } from '../../generated/prisma/client';
export declare class ServersService {
    private readonly prisma;
    private readonly haproxy;
    private readonly config;
    private readonly portMin;
    private readonly portMax;
    constructor(prisma: PrismaService, haproxy: HaproxyService, config: ConfigService);
    findAll(): Promise<Server[]>;
    create(dto: CreateServerDto): Promise<Server>;
    remove(id: number): Promise<void>;
    private allocatePort;
}
