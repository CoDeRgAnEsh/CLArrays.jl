using OpenCL: cl
using Transpiler: CLMethod, EmptyStruct
using Sugar
import GPUArrays: gpu_call, linear_index

immutable CLFunction{Args <: Tuple}
    program::cl.Kernel
    queue::cl.CmdQueue
    method::Nullable{CLMethod}
    source::String
end
function CLFunction{T, N}(A::CLArray{T, N}, f, args...)
    ctx = context(A)
    CLFunction(f, args, ctx.queue)
end
function (clfunc::CLFunction{T}){T, T2, N}(A::CLArray{T2, N}, args...)
    # TODO use better heuristic
    clfunc(args, length(A))
end

function gpu_call(f, A::CLArray, args::Tuple, blocks = nothing, thread = nothing)
    ctx = context(A)
    _args = if !isa(f, Tuple{String, Symbol})
        (KernelState(), args...) # CLArrays "state"
    else
        args
    end
    clfunc = CLFunction(f, _args, global_queue(ctx))
    if blocks == nothing
        blocks, thread = thread_blocks_heuristic(length(A))
    end
    clfunc(_args, blocks, thread)
end

#_to_cl_types{T}(::Type{T}) = T
_to_cl_types{T}(::T) = T
_to_cl_types{T}(::Type{T}) = Type{T}
_to_cl_types(::Int64) = Int32
_to_cl_types(::Float64) = Float32
_to_cl_types{T, N}(arg::CLArray{T, N}) = cli.CLArray{T, N}
_to_cl_types{T}(x::LocalMemory{T}) = cli.LocalMemory{T}
_to_cl_types(x::Ref{<: CLArray}) = _to_cl_types(x[])
function _to_cl_types{T <: Union{cl.Buffer, cl.CLArray}}(arg::T)
    return cli.CLArray{eltype(arg), ndims(arg)}
end
function to_cl_types(args::Union{Vector, Tuple})
    map(_to_cl_types, args)
end

cl_convert(x::Ref{<: CLArray}) = cl_convert(x[])
cl_convert(x::CLArray) = pointer(x)
cl_convert{T}(x::LocalMemory{T}) = cl.LocalMem(T, x.size)

function cl_convert{T}(x::T)
    # empty objects are empty and are only usable for dispatch
    isbits(x) && sizeof(x) == 0 && nfields(x) == 0 && return EmptyStruct()
    # same applies for types
    isa(x, Type) && return EmptyStruct()
    convert(_to_cl_types(x), x)
end

cl_convert(x::cl.CLArray) = pointer(x) # function objects are empty and are only usable for dispatch


const cl_compiled_functions = Dict{Any, CLFunction}()

function cl_empty_compile_cache!()
    empty!(cl_compiled_functions)
    return
end



function CLFunction{T}(f::Function, args::T, queue)
    ctx = cl.context(queue)
    device = first(cl.devices(ctx))
    version = cl_version(device)
    cltypes = to_cl_types(args)
    get!(cl_compiled_functions, (ctx.id, f, cltypes)) do # TODO make this faster
        source, method, fname = Transpiler.kernel_source(f, cltypes)
        println(source)
        options = "-cl-denorms-are-zero -cl-mad-enable -cl-unsafe-math-optimizations"
        if version > v"1.2"
            options *= " -cl-std=CL1.2"
        end
        p = cl.build!(
            cl.Program(ctx, source = source),
            options = options
        )
        k = cl.Kernel(p, fname)
        CLFunction{T}(k, queue, method, source)
    end::CLFunction{T}
end

function CLFunction{T}(source_name::Tuple{String, Symbol}, args::T, queue)
    kernelsource, funcname = source_name
    ctx = cl.context(queue)
    p = cl.build!(
        cl.Program(ctx, source = kernelsource),
        options = "-cl-denorms-are-zero -cl-mad-enable -cl-unsafe-math-optimizations"
    )
    k = cl.Kernel(p, string(funcname))
    CLFunction{T}(k, queue, Nullable{CLMethod}(), kernelsource)
end

# optimized version of launching a kernel... could go into OpenCL.jl
@generated function (program::CLFunction{T}){T}(
        args::T,
        global_work_size = nothing,
        local_work_size = nothing
    )
    # unrole set_arg! arguments
    unrolled = Expr(:block)
    idx = 0
    args_tuple = Sugar.to_tuple(args)
    kernel_idx = 1
    for (i, elem) in enumerate(args_tuple)
        if elem <: cl.CLArray
            idx = i
        end
        push!(unrolled.args, :(cl.set_arg!(k, $i, cl_convert(args[$kernel_idx]))))
        kernel_idx += 1
        contains, fields = Sugar.contains_tracked_type((), elem)
        if contains # global mem
            for field in fields
                push!(unrolled.args, :(
                    cl.set_arg!(k, $i, cl_convert(Sugar.get_fields(args[$kernel_idx], $(fields))))
                ))
                kernel_idx += 1
            end
        end
    end
    work_dim = if global_work_size <: Void
        if idx != 0
            :(size(args[$idx]))
        else
            error("either supply a global work size, or use a cl.Array to automatically infer global work size")
        end
    else
        :(global_work_size)
    end
    local_size = if local_work_size <: Void
        :(lsize = C_NULL)
    else
        quote
            lsize = Array{Csize_t}(length(gwork))
            for (i, s) in enumerate(local_work_size)
                lsize[i] = s
            end
        end
    end
    quote
        k = program.program
        q = program.queue
        $unrolled
        ret_event = Ref{cl.CL_event}()
        gwork = $work_dim
        gsize = Array{Csize_t}(length(gwork))
        for (i, s) in enumerate(gwork)
            gsize[i] = s
        end
        $local_size
        # TODO support everything from queue() in a performant manner
        cl.@check cl.api.clEnqueueNDRangeKernel(
            q.id, k.id,
            cl.cl_uint(length(gsize)), C_NULL, gsize, lsize,
            cl.cl_uint(0), C_NULL, ret_event
        )
        return cl.Event(ret_event[], retain = false)
    end
end
