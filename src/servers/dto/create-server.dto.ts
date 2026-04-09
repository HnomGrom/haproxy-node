import { IsIP, IsInt, IsString, Max, Min, MinLength } from 'class-validator';

export class CreateServerDto {
  @IsString()
  @MinLength(1)
  name: string;

  @IsIP()
  ip: string;

  @IsInt()
  @Min(1)
  @Max(65535)
  backendPort: number;
}
