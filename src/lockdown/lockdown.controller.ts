import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { ApiKeyGuard } from '../guards/api-key.guard';
import { IpListDto, LockdownOffDto } from './dto/lockdown.dto';
import { LockdownService } from './lockdown.service';

@UseGuards(ApiKeyGuard)
@Controller('lockdown')
export class LockdownController {
  constructor(private readonly lockdown: LockdownService) {}

  @Get('status')
  status() {
    return this.lockdown.status();
  }

  @Get('ips')
  listIps(@Query('limit') limit?: string) {
    const parsed = limit ? parseInt(limit, 10) : 1000;
    const safe = Number.isFinite(parsed) && parsed > 0 ? parsed : 1000;
    return this.lockdown.listIps(Math.min(safe, 100000));
  }

  @Post('ips/add')
  @HttpCode(HttpStatus.OK)
  addIps(@Body() dto: IpListDto) {
    return this.lockdown.addIps(dto.ips);
  }

  @Post('ips/remove')
  @HttpCode(HttpStatus.OK)
  removeIps(@Body() dto: IpListDto) {
    return this.lockdown.removeIps(dto.ips);
  }

  @Post('on')
  @HttpCode(HttpStatus.OK)
  enable(@Body() dto: IpListDto) {
    return this.lockdown.enable(dto.ips, dto.reason);
  }

  @Post('off')
  @HttpCode(HttpStatus.OK)
  disable(@Body() dto: LockdownOffDto) {
    return this.lockdown.disable(dto.reason);
  }
}
