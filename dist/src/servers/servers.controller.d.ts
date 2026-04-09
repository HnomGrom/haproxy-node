import { ServersService } from './servers.service';
import { CreateServerDto } from './dto/create-server.dto';
export declare class ServersController {
    private readonly serversService;
    constructor(serversService: ServersService);
    findAll(): Promise<{
        id: number;
        name: string;
        ip: string;
        backendPort: number;
        frontendPort: number;
        createdAt: Date;
    }[]>;
    create(dto: CreateServerDto): Promise<{
        id: number;
        name: string;
        ip: string;
        backendPort: number;
        frontendPort: number;
        createdAt: Date;
    }>;
    remove(id: number): Promise<void>;
}
