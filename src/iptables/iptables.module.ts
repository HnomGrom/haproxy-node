import { Module } from '@nestjs/common';
import { IptablesService } from './iptables.service';

@Module({
  providers: [IptablesService],
  exports: [IptablesService],
})
export class IptablesModule {}
