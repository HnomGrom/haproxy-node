import { Module } from '@nestjs/common';
import { HaproxyService } from './haproxy.service';

@Module({
  providers: [HaproxyService],
  exports: [HaproxyService],
})
export class HaproxyModule {}
