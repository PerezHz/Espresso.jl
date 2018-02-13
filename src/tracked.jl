
## tracked.jl - build ExGraph using tracked data types

import Base: +, -, *, /, log, exp, min, max, reshape, transpose, sum, mean,
    minimum, maximum, getindex


const DEFAULT_GRAPH = Ref(ExGraph())

get_default_graph() = DEFAULT_GRAPH[]
set_default_graph(g::ExGraph) = (DEFAULT_GRAPH[] = g)
reset_default_graph() = (DEFAULT_GRAPH[] = ExGraph())
swap_default_graph!(g::ExGraph) = (og = DEFAULT_GRAPH[]; DEFAULT_GRAPH[] = g; og)


## TRACKED REAL

struct TrackedReal <: Real
    graph::ExGraph
    var::Symbol
    val::Real
end

TrackedReal(var::Symbol, val::Real) = TrackedReal(get_default_graph(), var, val)
Base.show(io::IO, x::TrackedReal) = print(io, "Tracked($(x.var) = $(x.val))")
tracked_val(g::ExGraph, var::Symbol, val::Real) = TrackedReal(g, var, val)

struct TrackedArray{T,N} <: AbstractArray{T,N}
    graph::ExGraph
    var::Symbol
    val::AbstractArray{T,N}
end

TrackedArray(var::Symbol, val::AbstractArray) = TrackedArray(get_default_graph(), var, val)

Base.show(io::IO, x::TrackedArray{T,N}) where {T,N} =
    print(io, "Tracked{$T,$N}($(x.var) = $(x.val))")
Base.show(io::IO, ::MIME{Symbol("text/plain")}, x::TrackedArray{T,N}) where {T,N} =
    print(io, "Tracked{$T,$N}($(x.var) = $(x.val))")

tracked_val(g::ExGraph, var::Symbol, val::AbstractArray) = TrackedArray(g, var, val)

## conversion and promotion


tracked(g::ExGraph, x::TrackedReal) = x
tracked(g::ExGraph, x::TrackedArray) = x

function tracked(g::ExGraph, x::T) where {T <: Real}
    var = genname()
    push!(g, ExNode{:constant}(var, x; val=x))
    return TrackedReal(g, var, x)
end

function tracked(g::ExGraph, x::T) where {T <: AbstractArray}
    var = genname()
    push!(g, ExNode{:constant}(var, x; val=x))
    return TrackedArray(g, var, x)
end


value(x::TrackedArray) = x.v
value(x::TrackedReal) = x.v
value(x) = x

istracked(x::TrackedReal) = true
istracked(x::TrackedArray) = true
istracked(::Type{T}) where T = (T <: TrackedReal || T <: TrackedArray)
istracked(x) = false


Base.promote_rule(::Type{TrackedReal}, ::Type{<:Real}) = TrackedReal

function Base.convert(::Type{TrackedReal}, x::R) where {R <: Real}
    var = genname()
    g = get_default_graph()
    push!(g, ExNode{:constant}(var, x; val=x))
    return TrackedReal(g, var, x)
end

Base.convert(::Type{TrackedReal}, x::TrackedReal) = x


## TRACKED ARRAY


# TODO: should write this to graph? presumably no
Base.size(x::TrackedArray) = size(x.val)
# TODO: and these? presumably yes, but be carefull about printing
# Base.getindex(x::TrackedArray, I...) = getindex(x.val, I...)
# Base.setindex!(x::TrackedArray, val, I...) = setindex!(x.val, val, I...)


## conversion and promotion

Base.promote_rule(::Type{TrackedArray}, ::Type{<:AbstractArray}) = TrackedArray

function Base.convert(::Type{TrackedArray}, x::A) where {A <: AbstractArray}
    var = genname()
    g = get_default_graph()
    push!(g, ExNode{:constant}(var, x; val=x))
    return TrackedArray(g, var, x)
end

Base.convert(::Type{TrackedArray}, x::TrackedArray) = x


## @tracked macro

function track_call(sig)
    @assert sig.head == :call
    op = sig.args[1]
    vars_types, kw = split_params(sig)
    call_ex = nothing; ex_in_ex = nothing
    if isempty(kw)
        call_ex = Expr(:call, op,
                       [istracked(eval(t)) ? :($(v).val) : v for (v, t) in vars_types]...)
        ex_in_ex = Expr(:call, :Expr, QuoteNode(:call), QuoteNode(op),
                        [istracked(eval(t)) ? Expr(:., sig_var, QuoteNode(:var)) : sig_var
                         for (sig_var, t) in vars_types]...)
    else
        call_ex = Expr(:call, op, make_kw_params(kw),
                       [istracked(eval(t)) ? :($(v).val) : v for (v, t) in vars_types]...)
        keys = [k for (k, v) in kw]
        # we need to get this:
        # :( Expr(:call, :mult, Expr(:parameters, Expr(:kw, :pow, pow)), :(x.var)) )
        ex_in_ex = Expr(:call, :Expr, QuoteNode(:call), QuoteNode(op),
                        Expr(:call, :Expr, QuoteNode(:parameters),
                             [Expr(:call, :Expr, QuoteNode(:kw), QuoteNode(k), k)
                             for k in keys]...),
                        [istracked(eval(t)) ? Expr(:., sig_var, QuoteNode(:var)) : sig_var
                         for (sig_var, t) in vars_types]...)
    end
    defquot = quote
        function $op($(sig.args[2:end]...))
            val = $call_ex
            tv = tracked_val(x.graph, genname(), val) # TODO: x may be undefined
            ex = $ex_in_ex
            nd = ExNode{:call}(tv.var, ex; val=val)
            push!(x.graph, nd)
            return tv
        end
    end
    return defquot.args[2]
end


function track_bcast(sig)
    @assert sig.head == :.
    op = sig.args[1]
    sig_vars, types = unzip([(arg.args[1], eval(arg.args[2])) for arg in sig.args[2].args])
    bcast_ex = Expr(:., op, Expr(:tuple, [istracked(t) ? :($(v).val) : v
                                          for (v, t) in zip(sig_vars, types)]...))
    # we want to get this after code generation:
    # ex = :(Expr(:., :sin, Expr(:tuple, x.var, y.var)))
    ex_in_ex = Expr(:call, :Expr, QuoteNode(:.), QuoteNode(op),
                    Expr(:call, :Expr, QuoteNode(:tuple),
                         [Expr(:., sig_var, QuoteNode(:var)) for sig_var in sig_vars]...))
    defquot = quote
        function broadcast_(::typeof($op), $(sig.args[2].args...))
            val = $bcast_ex
            tv = tracked_val(x.graph, genname(), val) # TODO: x may be undefined
            ex = $ex_in_ex
            # println(ex)
            nd = ExNode{:bcast}(tv.var, ex; val=val)
            push!(x.graph, nd)
            return tv
        end
    end
    return defquot.args[2]
end


"""
Define a function or broadcasting rule for the specified signature which computes
the result as for ordinary (not tracked) data and writes it to the graph.

Note: this function expects at least 1 parameter of TrackedReal or TrackedArray type
with name `x`.
"""
macro tracked(sig)
    if sig.head == :call
        return track_call(sig)
    elseif sig.head == :.
        # TODO: we also need to add the op to broadcast list in `unfuse.jl`
        return track_bcast(sig)
    else
        error("Can only track calls or broadcasting")
    end
end


@tracked +(x::TrackedReal, y::TrackedReal)
@tracked -(x::TrackedReal, y::TrackedReal)
@tracked *(x::TrackedReal, y::TrackedReal)
@tracked /(x::TrackedReal, y::TrackedReal)

@tracked *(x::TrackedArray, y::TrackedArray)
@tracked maximum(x::TrackedArray)

@tracked getindex(x::TrackedArray, i::Integer)
@tracked getindex(x::TrackedArray, i::Integer, j::Integer)
@tracked getindex(x::TrackedArray, i::Integer, j::Integer, k::Integer)
@tracked getindex(x::TrackedArray, i::Integer, j::Integer, k::Integer, l::Integer)

@tracked reshape(x::TrackedArray, dims::Tuple{Int})
@tracked reshape(x::TrackedArray, dims::Tuple{Int, Int})
@tracked reshape(x::TrackedArray, dims::Tuple{Int, Int, Int})
@tracked reshape(x::TrackedArray, dims::Tuple{Int, Int, Int, Int})
@tracked reshape(x::TrackedArray, dims::Tuple{Int, Int, Int, Int, Int})
@tracked reshape(x::TrackedArray, dims::Tuple{Int, Int, Int, Int, Int, Int})

@tracked sum(x::TrackedArray)
@tracked mean(x::TrackedArray)

@tracked sin.(x::TrackedArray)
@tracked cos.(x::TrackedArray)
@tracked exp.(x::TrackedArray)
@tracked log.(x::TrackedArray)


## why this one doesn't work?
# for (op, dotop) in [(+, .+), (-, .-), (*, .*), (/, ./)]
#     @eval function broadcast_(::typeof($op), x::TrackedArray, y::TrackedArray)
#         val = $dotop(x.val, y.val)
#         var = genname()
#         nd = ExNode{:call}(var, :($(x.var) $dotop $(y.var)); val=val)
#         push!(x.graph, nd)
#         return TrackedArray(var, val)
#     end
# end


# I couldn't find a way to overload .+ and friends as either call or broadcasting
# fortunately, the list of such unusual operations is small and fixed
function broadcast_(::typeof(+), x::TrackedArray, y::TrackedArray)
    val = x.val .+ y.val
    var = genname()
    nd = ExNode{:call}(var, :($(x.var) .+ $(y.var)); val=val)
    push!(x.graph, nd)
    return TrackedArray(var, val)
end
function broadcast_(::typeof(-), x::TrackedArray, y::TrackedArray)
    val = x.val .- y.val
    var = genname()
    nd = ExNode{:call}(var, :($(x.var) .- $(y.var)); val=val)
    push!(x.graph, nd)
    return TrackedArray(var, val)
end
function broadcast_(::typeof(*), x::TrackedArray, y::TrackedArray)
    val = x.val .* y.val
    var = genname()
    nd = ExNode{:call}(var, :($(x.var) .* $(y.var)); val=val)
    push!(x.graph, nd)
    return TrackedArray(var, val)
end
function broadcast_(::typeof(/), x::TrackedArray, y::TrackedArray)
    val = x.val ./ y.val
    var = genname()
    nd = ExNode{:call}(var, :($(x.var) ./ $(y.var)); val=val)
    push!(x.graph, nd)
    return TrackedArray(var, val)
end