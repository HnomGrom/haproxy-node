import { Module } from '@nestjs/common';
import { CrowdsecService } from './crowdsec.service';

@Module({
  providers: [CrowdsecService],
  exports: [CrowdsecService],
})
export class CrowdsecModule {}
