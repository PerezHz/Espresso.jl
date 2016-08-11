

const DIFF_PHS = Set([:x, :y, :z, :a, :b, :c, :m, :n])

@runonce const DIFF_RULES =
        Dict{Tuple{OpName,Vector{Type}, Int}, Tuple{Symbolic,Any}}()


opname(op) = canonical(op)


macro diff_rule(ex::Expr, idx::Int, dex::Any)
    if ex.head == :call
        op = opname(ex.args[1])
        types = [eval(exa.args[2]) for exa in ex.args[2:end]]
        new_args = Symbol[exa.args[1] for exa in ex.args[2:end]]        
        ex_no_types = Expr(ex.head, ex.args[1], new_args...)
        DIFF_RULES[(op, types, idx)] = (ex_no_types, dex)
    else
        error("Can only define derivative on calls and assignments")
    end
end


function type_ansestors{T}(t::Type{T})
    types = Type[]
    while t != Any
        push!(types, t)
        t = @compat supertype(t)
    end
    push!(types, Any)
    return types
end


function find_rule(op::OpName, types::Vector{DataType}, idx::Int)
    type_ans = map(type_ansestors, types)
    type_products = product(type_ans...)
    ks = [(op, [tp...], idx) for tp in type_products]
    for k in ks
        if haskey(DIFF_RULES, k)
            return Nullable(DIFF_RULES[k])
        end
    end
    return Nullable()
end


function apply_rule(rule::Tuple{Expr, Any}, ex::Expr)
    return rewrite(ex, rule[1], rule[2]; phs=DIFF_PHS)
end


## basic rules

@diff_rule (-x::Number) 1 -1

@diff_rule (x::Number * y::Number) 1 y
@diff_rule (x::Number * y::Number) 2 x

@diff_rule (x::Number / y::Number) 1 (x / y)
@diff_rule (x::AbstractArray / y::Number) 1 x ./ y

@diff_rule (n::Number / x::Real) 2 (-n * x ^ -2)
@diff_rule (x::AbstractArray / y::Real) 2 (sum(-x .* y) / (y * y))


@diff_rule (x::Any + y::Any) 1 1
@diff_rule (x::Any + y::Any) 2 1
@diff_rule (x::Any + y::Any + z::Any) 1 1
@diff_rule (x::Any + y::Any + z::Any) 2 1
@diff_rule (x::Any + y::Any + z::Any) 3 1
@diff_rule (w::Any + x::Any + y::Any + z::Any) 1 1
@diff_rule (w::Any + x::Any + y::Any + z::Any) 2 1
@diff_rule (w::Any + x::Any + y::Any + z::Any) 3 1
@diff_rule (w::Any + x::Any + y::Any + z::Any) 4 1

@diff_rule (x::Any .+ y::Any) 1 1
@diff_rule (x::Any .+ y::Any) 2 1

@diff_rule (x::Any - y::Any) 1 1
@diff_rule (x::Any - y::Any) 2 -1

@diff_rule (x::Any .- y::Any) 1 1
@diff_rule (x::Any .- y::Any) 2 -1

@diff_rule sin(x::Number) 1 cos(x)
@diff_rule cos(x::Number) 1 -sin(x)

@diff_rule sqrt(x::Number) 1 (0.5 * x^(-0.5))
@diff_rule sqrt(x::AbstractVector) 1 (0.5 .* x .^ (-0.5))


@diff_rule exp(x::Number) 1 exp(x)

@diff_rule (x::Number ^ n::Int) 1 (n * x^(n-1))
@diff_rule (a::Number ^ x::Number) 2 (log(a) * a^x)

@diff_rule log(x::Number) 1 (1/x)
# TODO: log_b(x) = ln(x) / ln(b) --> infer rule for 1st arg (b)
@diff_rule log(b::Int, x::Number) 2 (1 / (x * log(b)))


# abs

@diff_rule abs(x::Number) 1 (sign(x) * x)
@diff_rule abs(x::AbstractArray) 1 (sign(x) .* x)

# min, max

@diff_rule max(x::Number, y::Number) 1 (x > y) * x
@diff_rule max(x::Number, y::Number) 2 (y > x) * y

@diff_rule min(x::Number, y::Number) 1 (x < y) * x
@diff_rule min(x::Number, y::Number) 2 (y < x) * y
