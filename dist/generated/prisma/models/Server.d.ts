import type * as runtime from "@prisma/client/runtime/client";
import type * as Prisma from "../internal/prismaNamespace";
export type ServerModel = runtime.Types.Result.DefaultSelection<Prisma.$ServerPayload>;
export type AggregateServer = {
    _count: ServerCountAggregateOutputType | null;
    _avg: ServerAvgAggregateOutputType | null;
    _sum: ServerSumAggregateOutputType | null;
    _min: ServerMinAggregateOutputType | null;
    _max: ServerMaxAggregateOutputType | null;
};
export type ServerAvgAggregateOutputType = {
    id: number | null;
    backendPort: number | null;
    frontendPort: number | null;
};
export type ServerSumAggregateOutputType = {
    id: number | null;
    backendPort: number | null;
    frontendPort: number | null;
};
export type ServerMinAggregateOutputType = {
    id: number | null;
    name: string | null;
    ip: string | null;
    backendPort: number | null;
    frontendPort: number | null;
    createdAt: Date | null;
};
export type ServerMaxAggregateOutputType = {
    id: number | null;
    name: string | null;
    ip: string | null;
    backendPort: number | null;
    frontendPort: number | null;
    createdAt: Date | null;
};
export type ServerCountAggregateOutputType = {
    id: number;
    name: number;
    ip: number;
    backendPort: number;
    frontendPort: number;
    createdAt: number;
    _all: number;
};
export type ServerAvgAggregateInputType = {
    id?: true;
    backendPort?: true;
    frontendPort?: true;
};
export type ServerSumAggregateInputType = {
    id?: true;
    backendPort?: true;
    frontendPort?: true;
};
export type ServerMinAggregateInputType = {
    id?: true;
    name?: true;
    ip?: true;
    backendPort?: true;
    frontendPort?: true;
    createdAt?: true;
};
export type ServerMaxAggregateInputType = {
    id?: true;
    name?: true;
    ip?: true;
    backendPort?: true;
    frontendPort?: true;
    createdAt?: true;
};
export type ServerCountAggregateInputType = {
    id?: true;
    name?: true;
    ip?: true;
    backendPort?: true;
    frontendPort?: true;
    createdAt?: true;
    _all?: true;
};
export type ServerAggregateArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    where?: Prisma.ServerWhereInput;
    orderBy?: Prisma.ServerOrderByWithRelationInput | Prisma.ServerOrderByWithRelationInput[];
    cursor?: Prisma.ServerWhereUniqueInput;
    take?: number;
    skip?: number;
    _count?: true | ServerCountAggregateInputType;
    _avg?: ServerAvgAggregateInputType;
    _sum?: ServerSumAggregateInputType;
    _min?: ServerMinAggregateInputType;
    _max?: ServerMaxAggregateInputType;
};
export type GetServerAggregateType<T extends ServerAggregateArgs> = {
    [P in keyof T & keyof AggregateServer]: P extends '_count' | 'count' ? T[P] extends true ? number : Prisma.GetScalarType<T[P], AggregateServer[P]> : Prisma.GetScalarType<T[P], AggregateServer[P]>;
};
export type ServerGroupByArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    where?: Prisma.ServerWhereInput;
    orderBy?: Prisma.ServerOrderByWithAggregationInput | Prisma.ServerOrderByWithAggregationInput[];
    by: Prisma.ServerScalarFieldEnum[] | Prisma.ServerScalarFieldEnum;
    having?: Prisma.ServerScalarWhereWithAggregatesInput;
    take?: number;
    skip?: number;
    _count?: ServerCountAggregateInputType | true;
    _avg?: ServerAvgAggregateInputType;
    _sum?: ServerSumAggregateInputType;
    _min?: ServerMinAggregateInputType;
    _max?: ServerMaxAggregateInputType;
};
export type ServerGroupByOutputType = {
    id: number;
    name: string;
    ip: string;
    backendPort: number;
    frontendPort: number;
    createdAt: Date;
    _count: ServerCountAggregateOutputType | null;
    _avg: ServerAvgAggregateOutputType | null;
    _sum: ServerSumAggregateOutputType | null;
    _min: ServerMinAggregateOutputType | null;
    _max: ServerMaxAggregateOutputType | null;
};
export type GetServerGroupByPayload<T extends ServerGroupByArgs> = Prisma.PrismaPromise<Array<Prisma.PickEnumerable<ServerGroupByOutputType, T['by']> & {
    [P in ((keyof T) & (keyof ServerGroupByOutputType))]: P extends '_count' ? T[P] extends boolean ? number : Prisma.GetScalarType<T[P], ServerGroupByOutputType[P]> : Prisma.GetScalarType<T[P], ServerGroupByOutputType[P]>;
}>>;
export type ServerWhereInput = {
    AND?: Prisma.ServerWhereInput | Prisma.ServerWhereInput[];
    OR?: Prisma.ServerWhereInput[];
    NOT?: Prisma.ServerWhereInput | Prisma.ServerWhereInput[];
    id?: Prisma.IntFilter<"Server"> | number;
    name?: Prisma.StringFilter<"Server"> | string;
    ip?: Prisma.StringFilter<"Server"> | string;
    backendPort?: Prisma.IntFilter<"Server"> | number;
    frontendPort?: Prisma.IntFilter<"Server"> | number;
    createdAt?: Prisma.DateTimeFilter<"Server"> | Date | string;
};
export type ServerOrderByWithRelationInput = {
    id?: Prisma.SortOrder;
    name?: Prisma.SortOrder;
    ip?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
    createdAt?: Prisma.SortOrder;
};
export type ServerWhereUniqueInput = Prisma.AtLeast<{
    id?: number;
    name?: string;
    frontendPort?: number;
    AND?: Prisma.ServerWhereInput | Prisma.ServerWhereInput[];
    OR?: Prisma.ServerWhereInput[];
    NOT?: Prisma.ServerWhereInput | Prisma.ServerWhereInput[];
    ip?: Prisma.StringFilter<"Server"> | string;
    backendPort?: Prisma.IntFilter<"Server"> | number;
    createdAt?: Prisma.DateTimeFilter<"Server"> | Date | string;
}, "id" | "name" | "frontendPort">;
export type ServerOrderByWithAggregationInput = {
    id?: Prisma.SortOrder;
    name?: Prisma.SortOrder;
    ip?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
    createdAt?: Prisma.SortOrder;
    _count?: Prisma.ServerCountOrderByAggregateInput;
    _avg?: Prisma.ServerAvgOrderByAggregateInput;
    _max?: Prisma.ServerMaxOrderByAggregateInput;
    _min?: Prisma.ServerMinOrderByAggregateInput;
    _sum?: Prisma.ServerSumOrderByAggregateInput;
};
export type ServerScalarWhereWithAggregatesInput = {
    AND?: Prisma.ServerScalarWhereWithAggregatesInput | Prisma.ServerScalarWhereWithAggregatesInput[];
    OR?: Prisma.ServerScalarWhereWithAggregatesInput[];
    NOT?: Prisma.ServerScalarWhereWithAggregatesInput | Prisma.ServerScalarWhereWithAggregatesInput[];
    id?: Prisma.IntWithAggregatesFilter<"Server"> | number;
    name?: Prisma.StringWithAggregatesFilter<"Server"> | string;
    ip?: Prisma.StringWithAggregatesFilter<"Server"> | string;
    backendPort?: Prisma.IntWithAggregatesFilter<"Server"> | number;
    frontendPort?: Prisma.IntWithAggregatesFilter<"Server"> | number;
    createdAt?: Prisma.DateTimeWithAggregatesFilter<"Server"> | Date | string;
};
export type ServerCreateInput = {
    name: string;
    ip: string;
    backendPort: number;
    frontendPort: number;
    createdAt?: Date | string;
};
export type ServerUncheckedCreateInput = {
    id?: number;
    name: string;
    ip: string;
    backendPort: number;
    frontendPort: number;
    createdAt?: Date | string;
};
export type ServerUpdateInput = {
    name?: Prisma.StringFieldUpdateOperationsInput | string;
    ip?: Prisma.StringFieldUpdateOperationsInput | string;
    backendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    frontendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    createdAt?: Prisma.DateTimeFieldUpdateOperationsInput | Date | string;
};
export type ServerUncheckedUpdateInput = {
    id?: Prisma.IntFieldUpdateOperationsInput | number;
    name?: Prisma.StringFieldUpdateOperationsInput | string;
    ip?: Prisma.StringFieldUpdateOperationsInput | string;
    backendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    frontendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    createdAt?: Prisma.DateTimeFieldUpdateOperationsInput | Date | string;
};
export type ServerCreateManyInput = {
    id?: number;
    name: string;
    ip: string;
    backendPort: number;
    frontendPort: number;
    createdAt?: Date | string;
};
export type ServerUpdateManyMutationInput = {
    name?: Prisma.StringFieldUpdateOperationsInput | string;
    ip?: Prisma.StringFieldUpdateOperationsInput | string;
    backendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    frontendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    createdAt?: Prisma.DateTimeFieldUpdateOperationsInput | Date | string;
};
export type ServerUncheckedUpdateManyInput = {
    id?: Prisma.IntFieldUpdateOperationsInput | number;
    name?: Prisma.StringFieldUpdateOperationsInput | string;
    ip?: Prisma.StringFieldUpdateOperationsInput | string;
    backendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    frontendPort?: Prisma.IntFieldUpdateOperationsInput | number;
    createdAt?: Prisma.DateTimeFieldUpdateOperationsInput | Date | string;
};
export type ServerCountOrderByAggregateInput = {
    id?: Prisma.SortOrder;
    name?: Prisma.SortOrder;
    ip?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
    createdAt?: Prisma.SortOrder;
};
export type ServerAvgOrderByAggregateInput = {
    id?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
};
export type ServerMaxOrderByAggregateInput = {
    id?: Prisma.SortOrder;
    name?: Prisma.SortOrder;
    ip?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
    createdAt?: Prisma.SortOrder;
};
export type ServerMinOrderByAggregateInput = {
    id?: Prisma.SortOrder;
    name?: Prisma.SortOrder;
    ip?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
    createdAt?: Prisma.SortOrder;
};
export type ServerSumOrderByAggregateInput = {
    id?: Prisma.SortOrder;
    backendPort?: Prisma.SortOrder;
    frontendPort?: Prisma.SortOrder;
};
export type StringFieldUpdateOperationsInput = {
    set?: string;
};
export type IntFieldUpdateOperationsInput = {
    set?: number;
    increment?: number;
    decrement?: number;
    multiply?: number;
    divide?: number;
};
export type DateTimeFieldUpdateOperationsInput = {
    set?: Date | string;
};
export type ServerSelect<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = runtime.Types.Extensions.GetSelect<{
    id?: boolean;
    name?: boolean;
    ip?: boolean;
    backendPort?: boolean;
    frontendPort?: boolean;
    createdAt?: boolean;
}, ExtArgs["result"]["server"]>;
export type ServerSelectCreateManyAndReturn<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = runtime.Types.Extensions.GetSelect<{
    id?: boolean;
    name?: boolean;
    ip?: boolean;
    backendPort?: boolean;
    frontendPort?: boolean;
    createdAt?: boolean;
}, ExtArgs["result"]["server"]>;
export type ServerSelectUpdateManyAndReturn<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = runtime.Types.Extensions.GetSelect<{
    id?: boolean;
    name?: boolean;
    ip?: boolean;
    backendPort?: boolean;
    frontendPort?: boolean;
    createdAt?: boolean;
}, ExtArgs["result"]["server"]>;
export type ServerSelectScalar = {
    id?: boolean;
    name?: boolean;
    ip?: boolean;
    backendPort?: boolean;
    frontendPort?: boolean;
    createdAt?: boolean;
};
export type ServerOmit<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = runtime.Types.Extensions.GetOmit<"id" | "name" | "ip" | "backendPort" | "frontendPort" | "createdAt", ExtArgs["result"]["server"]>;
export type $ServerPayload<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    name: "Server";
    objects: {};
    scalars: runtime.Types.Extensions.GetPayloadResult<{
        id: number;
        name: string;
        ip: string;
        backendPort: number;
        frontendPort: number;
        createdAt: Date;
    }, ExtArgs["result"]["server"]>;
    composites: {};
};
export type ServerGetPayload<S extends boolean | null | undefined | ServerDefaultArgs> = runtime.Types.Result.GetResult<Prisma.$ServerPayload, S>;
export type ServerCountArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = Omit<ServerFindManyArgs, 'select' | 'include' | 'distinct' | 'omit'> & {
    select?: ServerCountAggregateInputType | true;
};
export interface ServerDelegate<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs, GlobalOmitOptions = {}> {
    [K: symbol]: {
        types: Prisma.TypeMap<ExtArgs>['model']['Server'];
        meta: {
            name: 'Server';
        };
    };
    findUnique<T extends ServerFindUniqueArgs>(args: Prisma.SelectSubset<T, ServerFindUniqueArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "findUnique", GlobalOmitOptions> | null, null, ExtArgs, GlobalOmitOptions>;
    findUniqueOrThrow<T extends ServerFindUniqueOrThrowArgs>(args: Prisma.SelectSubset<T, ServerFindUniqueOrThrowArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "findUniqueOrThrow", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    findFirst<T extends ServerFindFirstArgs>(args?: Prisma.SelectSubset<T, ServerFindFirstArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "findFirst", GlobalOmitOptions> | null, null, ExtArgs, GlobalOmitOptions>;
    findFirstOrThrow<T extends ServerFindFirstOrThrowArgs>(args?: Prisma.SelectSubset<T, ServerFindFirstOrThrowArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "findFirstOrThrow", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    findMany<T extends ServerFindManyArgs>(args?: Prisma.SelectSubset<T, ServerFindManyArgs<ExtArgs>>): Prisma.PrismaPromise<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "findMany", GlobalOmitOptions>>;
    create<T extends ServerCreateArgs>(args: Prisma.SelectSubset<T, ServerCreateArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "create", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    createMany<T extends ServerCreateManyArgs>(args?: Prisma.SelectSubset<T, ServerCreateManyArgs<ExtArgs>>): Prisma.PrismaPromise<Prisma.BatchPayload>;
    createManyAndReturn<T extends ServerCreateManyAndReturnArgs>(args?: Prisma.SelectSubset<T, ServerCreateManyAndReturnArgs<ExtArgs>>): Prisma.PrismaPromise<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "createManyAndReturn", GlobalOmitOptions>>;
    delete<T extends ServerDeleteArgs>(args: Prisma.SelectSubset<T, ServerDeleteArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "delete", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    update<T extends ServerUpdateArgs>(args: Prisma.SelectSubset<T, ServerUpdateArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "update", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    deleteMany<T extends ServerDeleteManyArgs>(args?: Prisma.SelectSubset<T, ServerDeleteManyArgs<ExtArgs>>): Prisma.PrismaPromise<Prisma.BatchPayload>;
    updateMany<T extends ServerUpdateManyArgs>(args: Prisma.SelectSubset<T, ServerUpdateManyArgs<ExtArgs>>): Prisma.PrismaPromise<Prisma.BatchPayload>;
    updateManyAndReturn<T extends ServerUpdateManyAndReturnArgs>(args: Prisma.SelectSubset<T, ServerUpdateManyAndReturnArgs<ExtArgs>>): Prisma.PrismaPromise<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "updateManyAndReturn", GlobalOmitOptions>>;
    upsert<T extends ServerUpsertArgs>(args: Prisma.SelectSubset<T, ServerUpsertArgs<ExtArgs>>): Prisma.Prisma__ServerClient<runtime.Types.Result.GetResult<Prisma.$ServerPayload<ExtArgs>, T, "upsert", GlobalOmitOptions>, never, ExtArgs, GlobalOmitOptions>;
    count<T extends ServerCountArgs>(args?: Prisma.Subset<T, ServerCountArgs>): Prisma.PrismaPromise<T extends runtime.Types.Utils.Record<'select', any> ? T['select'] extends true ? number : Prisma.GetScalarType<T['select'], ServerCountAggregateOutputType> : number>;
    aggregate<T extends ServerAggregateArgs>(args: Prisma.Subset<T, ServerAggregateArgs>): Prisma.PrismaPromise<GetServerAggregateType<T>>;
    groupBy<T extends ServerGroupByArgs, HasSelectOrTake extends Prisma.Or<Prisma.Extends<'skip', Prisma.Keys<T>>, Prisma.Extends<'take', Prisma.Keys<T>>>, OrderByArg extends Prisma.True extends HasSelectOrTake ? {
        orderBy: ServerGroupByArgs['orderBy'];
    } : {
        orderBy?: ServerGroupByArgs['orderBy'];
    }, OrderFields extends Prisma.ExcludeUnderscoreKeys<Prisma.Keys<Prisma.MaybeTupleToUnion<T['orderBy']>>>, ByFields extends Prisma.MaybeTupleToUnion<T['by']>, ByValid extends Prisma.Has<ByFields, OrderFields>, HavingFields extends Prisma.GetHavingFields<T['having']>, HavingValid extends Prisma.Has<ByFields, HavingFields>, ByEmpty extends T['by'] extends never[] ? Prisma.True : Prisma.False, InputErrors extends ByEmpty extends Prisma.True ? `Error: "by" must not be empty.` : HavingValid extends Prisma.False ? {
        [P in HavingFields]: P extends ByFields ? never : P extends string ? `Error: Field "${P}" used in "having" needs to be provided in "by".` : [
            Error,
            'Field ',
            P,
            ` in "having" needs to be provided in "by"`
        ];
    }[HavingFields] : 'take' extends Prisma.Keys<T> ? 'orderBy' extends Prisma.Keys<T> ? ByValid extends Prisma.True ? {} : {
        [P in OrderFields]: P extends ByFields ? never : `Error: Field "${P}" in "orderBy" needs to be provided in "by"`;
    }[OrderFields] : 'Error: If you provide "take", you also need to provide "orderBy"' : 'skip' extends Prisma.Keys<T> ? 'orderBy' extends Prisma.Keys<T> ? ByValid extends Prisma.True ? {} : {
        [P in OrderFields]: P extends ByFields ? never : `Error: Field "${P}" in "orderBy" needs to be provided in "by"`;
    }[OrderFields] : 'Error: If you provide "skip", you also need to provide "orderBy"' : ByValid extends Prisma.True ? {} : {
        [P in OrderFields]: P extends ByFields ? never : `Error: Field "${P}" in "orderBy" needs to be provided in "by"`;
    }[OrderFields]>(args: Prisma.SubsetIntersection<T, ServerGroupByArgs, OrderByArg> & InputErrors): {} extends InputErrors ? GetServerGroupByPayload<T> : Prisma.PrismaPromise<InputErrors>;
    readonly fields: ServerFieldRefs;
}
export interface Prisma__ServerClient<T, Null = never, ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs, GlobalOmitOptions = {}> extends Prisma.PrismaPromise<T> {
    readonly [Symbol.toStringTag]: "PrismaPromise";
    then<TResult1 = T, TResult2 = never>(onfulfilled?: ((value: T) => TResult1 | PromiseLike<TResult1>) | undefined | null, onrejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | undefined | null): runtime.Types.Utils.JsPromise<TResult1 | TResult2>;
    catch<TResult = never>(onrejected?: ((reason: any) => TResult | PromiseLike<TResult>) | undefined | null): runtime.Types.Utils.JsPromise<T | TResult>;
    finally(onfinally?: (() => void) | undefined | null): runtime.Types.Utils.JsPromise<T>;
}
export interface ServerFieldRefs {
    readonly id: Prisma.FieldRef<"Server", 'Int'>;
    readonly name: Prisma.FieldRef<"Server", 'String'>;
    readonly ip: Prisma.FieldRef<"Server", 'String'>;
    readonly backendPort: Prisma.FieldRef<"Server", 'Int'>;
    readonly frontendPort: Prisma.FieldRef<"Server", 'Int'>;
    readonly createdAt: Prisma.FieldRef<"Server", 'DateTime'>;
}
export type ServerFindUniqueArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where: Prisma.ServerWhereUniqueInput;
};
export type ServerFindUniqueOrThrowArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where: Prisma.ServerWhereUniqueInput;
};
export type ServerFindFirstArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where?: Prisma.ServerWhereInput;
    orderBy?: Prisma.ServerOrderByWithRelationInput | Prisma.ServerOrderByWithRelationInput[];
    cursor?: Prisma.ServerWhereUniqueInput;
    take?: number;
    skip?: number;
    distinct?: Prisma.ServerScalarFieldEnum | Prisma.ServerScalarFieldEnum[];
};
export type ServerFindFirstOrThrowArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where?: Prisma.ServerWhereInput;
    orderBy?: Prisma.ServerOrderByWithRelationInput | Prisma.ServerOrderByWithRelationInput[];
    cursor?: Prisma.ServerWhereUniqueInput;
    take?: number;
    skip?: number;
    distinct?: Prisma.ServerScalarFieldEnum | Prisma.ServerScalarFieldEnum[];
};
export type ServerFindManyArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where?: Prisma.ServerWhereInput;
    orderBy?: Prisma.ServerOrderByWithRelationInput | Prisma.ServerOrderByWithRelationInput[];
    cursor?: Prisma.ServerWhereUniqueInput;
    take?: number;
    skip?: number;
    distinct?: Prisma.ServerScalarFieldEnum | Prisma.ServerScalarFieldEnum[];
};
export type ServerCreateArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    data: Prisma.XOR<Prisma.ServerCreateInput, Prisma.ServerUncheckedCreateInput>;
};
export type ServerCreateManyArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    data: Prisma.ServerCreateManyInput | Prisma.ServerCreateManyInput[];
};
export type ServerCreateManyAndReturnArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelectCreateManyAndReturn<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    data: Prisma.ServerCreateManyInput | Prisma.ServerCreateManyInput[];
};
export type ServerUpdateArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    data: Prisma.XOR<Prisma.ServerUpdateInput, Prisma.ServerUncheckedUpdateInput>;
    where: Prisma.ServerWhereUniqueInput;
};
export type ServerUpdateManyArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    data: Prisma.XOR<Prisma.ServerUpdateManyMutationInput, Prisma.ServerUncheckedUpdateManyInput>;
    where?: Prisma.ServerWhereInput;
    limit?: number;
};
export type ServerUpdateManyAndReturnArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelectUpdateManyAndReturn<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    data: Prisma.XOR<Prisma.ServerUpdateManyMutationInput, Prisma.ServerUncheckedUpdateManyInput>;
    where?: Prisma.ServerWhereInput;
    limit?: number;
};
export type ServerUpsertArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where: Prisma.ServerWhereUniqueInput;
    create: Prisma.XOR<Prisma.ServerCreateInput, Prisma.ServerUncheckedCreateInput>;
    update: Prisma.XOR<Prisma.ServerUpdateInput, Prisma.ServerUncheckedUpdateInput>;
};
export type ServerDeleteArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
    where: Prisma.ServerWhereUniqueInput;
};
export type ServerDeleteManyArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    where?: Prisma.ServerWhereInput;
    limit?: number;
};
export type ServerDefaultArgs<ExtArgs extends runtime.Types.Extensions.InternalArgs = runtime.Types.Extensions.DefaultArgs> = {
    select?: Prisma.ServerSelect<ExtArgs> | null;
    omit?: Prisma.ServerOmit<ExtArgs> | null;
};
