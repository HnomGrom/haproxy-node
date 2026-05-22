import { IsIP, IsInt, Max, Min } from 'class-validator';

export class CreateServerDto {
  @IsIP('4')
  ip: string;

  @IsInt()
  @Min(1)
  @Max(65535)
  backendPort: number;
}
