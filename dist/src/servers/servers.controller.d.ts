import { ServersService } from './servers.service';
import { CreateServerDto } from './dto/create-server.dto';
export declare class ServersController {
    private readonly serversService;
    constructor(serversService: ServersService);
    findAll(): Promise<{
        name: string;
        id: number;
        ip: string;
        backendPort: number;
        frontendPort: number;
        createdAt: Date;
    }[]>;
    create(dto: CreateServerDto): Promise<{
        name: string;
        id: number;
        ip: string;
        backendPort: number;
        frontendPort: number;
        createdAt: Date;
    }>;
    remove(id: number): Promise<void>;
}
