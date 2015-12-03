macro gputime(codeblock)
    quote
        local const query        = GLuint[1]
        local const elapsed_time = GLuint64[1]
        local const done         = GLint[0]
        glGenQueries(1, query)
        glBeginQuery(GL_TIME_ELAPSED, query[1])
        value = $(esc(codeblock))
        glEndQuery(GL_TIME_ELAPSED)

        while (done[1] != 1)
            glGetQueryObjectiv(
                query[1],
                GL_QUERY_RESULT_AVAILABLE,
                done
            )
        end
        glGetQueryObjectui64v(query[1], GL_QUERY_RESULT, elapsed_time)
        println("Time Elapsed: ", elapsed_time[1] / 1000000.0, "ms")
    end
end

immutable IterOrScalar{T}
  val::T
end

minlenght(a::Tuple{Vararg{IterOrScalar}}) = foldl(typemax(Int), a) do len, elem
    isa(elem.val, AbstractArray) && len > length(elem.val) && return length(elem.val)
    len
end
getindex{T<:AbstractArray}(A::IterOrScalar{T}, i::Integer) = A.val[i]
getindex(A::IterOrScalar, i::Integer) = A.val

foreach(func::Union{Function, DataType}, args...) = foreach(func, map(IterOrScalar, args)...)

# Applies a function over multiple args
# staged, so it can specialize on the arguments being scalar or iterable
@generated function foreach(func::Function, args::IterOrScalar...)
    args_access = [:(args[$i][i]) for i=1:length(args)]
    quote
        len = minlenght(args)
        for i=1:len
            func($(args_access...))
        end
    end
end

#Some mapping functions for dictionaries
mapvalues(func::Union{Function, Base.Func}, collection::Dict) =
    [key => func(value) for (key, value) in collection]
mapkeys(func::Union{Function, Base.Func}, collection::Dict) =
    [func(key) => value for (key, value) in collection]
Base.get{KT, VT}(a::Dict{KT, VT}, keys::Vector{KT}) = [a[key] for key in keys]

function print_with_lines(text::AbstractString)
    for (i,line) in enumerate(split(text, "\n"))
        @printf("%-4d: %s\n", i, line)
    end
end


"""
Style Type, which is used to choose different visualization/editing styles via multiple dispatch
Usage pattern:
visualize(::Style{:Default}, ...)           = do something
visualize(::Style{:MyAwesomeNewStyle}, ...) = do something different
"""
immutable Style{StyleValue}
end
Style(x::Symbol) = Style{x}()
Style() = Style{:Default}()
mergedefault!{S}(style::Style{S}, styles, customdata) = merge!(copy(styles[S]), Dict{Symbol, Any}(customdata))
macro style_str(string)
    Style{symbol(string)}
end
export @style_str

"""
splats keys from a dict into variables
"""
macro materialize(dict_splat)
    keynames, dict = dict_splat.args
    keynames = isa(keynames, Symbol) ? [keynames] : keynames.args
    dict_instance = gensym()
    kd = [:($key = $dict_instance[$(Expr(:quote, key))]) for key in keynames]
    kdblock = Expr(:block, kd...)
    expr = quote
        $dict_instance = $dict # handle if dict is not a variable but an expression
        $kdblock
    end
    esc(expr)
end
"""
splats keys from a dict into variables and removes them
"""
macro materialize!(dict_splat)
    keynames, dict = dict_splat.args
    keynames = isa(keynames, Symbol) ? [keynames] : keynames.args
    dict_instance = gensym()
    kd = [:($key = pop!($dict_instance, $(Expr(:quote, key)))) for key in keynames]
    kdblock = Expr(:block, kd...)
    expr = quote
        $dict_instance = $dict # handle if dict is not a variable but an expression
        $kdblock
    end
    esc(expr)
end


"""
Needed to match the lazy gl_convert exceptions.
    `Target`: targeted OpenGL type
    `x`: the variable that gets matched
"""
matches_target{Target, T}(::Type{Target}, x::T) = applicable(gl_convert, Target, x) || T <: Target  # it can be either converted to Target, or it's already the target
matches_target{Target, T}(::Type{Target}, x::Signal{T}) = applicable(gl_convert, Target, x)  || T <: Target
export matches_target



"""
Takes a dict and inserts defaults, if not already available.
The variables are made accessible in local scope, so things like this are possible:
gen_defaults! dict begin
    a = 55
    b = a * 2 # variables, like a, will get made visible in local scope
    c::JuliaType = X # `c` needs to be of type JuliaType. `c` will be made available with it's original type and then converted to JuliaType when inserted into `dict`
    d = x => GLType # OpenGL convert target. Get's only applied if `x` is convertible to GLType. Will only be converted when passed to RenderObject
end
"""
macro gen_defaults!(dict, args)
    args.head == :block || error("second argument needs to be a block of form
    begin
        a = 55
        b = a * 2 # variables, like a, will get made visible in local scope
        c::JuliaType = X # c needs to be of type JuliaType. c will be made available with it's original type and then converted to JuliaType when inserted into data
        d = x => GLType # OpenGL convert target. Get's only applied if x is convertible to GLType. Will only be converted when passed to RenderObject
    end")
    tuple_list = args.args
    dictsym = gensym()
    return_expression = Expr(:block)
    push!(return_expression.args, :($dictsym = $dict)) # dict could also be an expression, so we need to asign it to a variable at the beginning
    push!(return_expression.args, :(gl_convert_targets = get($dictsym, :gl_convert_targets, Dict{Symbol, Type}()))) # exceptions for glconvert.
    # @gen_defaults can be used multiple times, so we need to reuse gl_convert_targets if already in here
    for (i,elem) in enumerate(tuple_list)
        elem.head == :line && continue
        opengl_convert_target = :() # is optional, so first is an empty expression
        convert_target        = :() # is optional, so first is an empty expression
        if elem.head == :(=)
            key_name, value_expr = elem.args
            if isa(key_name, Expr) && key_name.head == :(::) # we need to convert to a julia type
                key_name, convert_target = key_name.args
                convert_target = :($key_name = convert($convert_target, $key_name))
            end
            key_sym = Expr(:quote, key_name)
            if key_name == :prerender
                continue
            end
            if isa(value_expr, Expr) && value_expr.head == :(=>)  # we might need to insert a convert target
                value_expr, target = value_expr.args
                opengl_convert_target = quote
                    if matches_target($target, $key_name)
                        gl_convert_targets[$key_sym] = $target
                    end
                end
            end
            expr = quote
                $key_name = haskey($dictsym, $key_sym) ? $dictsym[$key_sym] : $value_expr # in case that evaluating value_expr is expensive, we use a branch instead of get(dict, key, default)
                $convert_target
                $dictsym[$key_sym] = $key_name
                $opengl_convert_target
            end
            push!(return_expression.args, expr)
        else
            error("all nodes need to be of form a = b OR a::Type = b OR a = b => Type, where a needs to be a var and b any expression. Found: $elem")
        end
    end
    push!(return_expression.args, :($dictsym[:gl_convert_targets] = gl_convert_targets)) #just pass the targets via the dict
    push!(return_expression.args, :($dictsym)) #return dict
    esc(return_expression)
end
export @gen_defaults!


value(any) = any # add this, to make it easier to work with a combination of signals and constants

makesignal(s::Signal) = s
makesignal(v)         = Signal(v)

@inline const_lift(f::Union{DataType, Function}, inputs...) = map(f, map(makesignal, inputs)...)
export const_lift

function close_to_square(n::Real)
    # a cannot be greater than the square root of n
    # b cannot be smaller than the square root of n
    # we get the maximum allowed value of a
    amax = floor(Int, sqrt(n));
    if 0 == rem(n, amax)
        # special case where n is a square number
        return (amax, div(n, amax))
    end
    # Get its prime factors of n
    primeFactors  = factor(n);
    # Start with a factor 1 in the list of candidates for a
    candidates = Int[1]
    for (f, _) in primeFactors
        # Add new candidates which are obtained by multiplying
        # existing candidates with the new prime factor f
        # Set union ensures that duplicate candidates are removed
        candidates  = union(candidates, f .* candidates);
        # throw out candidates which are larger than amax
        filter!(x-> x <= amax, candidates)
    end
    # Take the largest factor in the list d
    (candidates[end], div(n, candidates[end]))
end



isnotempty(x) = !isempty(x)
AND(a,b) = a&&b
OR(a,b) = a||b


#Uhm I should remove this. Needed for smooth transition between FixedSizeArrays and Number, though
Base.length{T <: Number}(::Type{T}) = 1


#Meshtype holding native OpenGL data.
immutable NativeMesh{MeshType <: HomogenousMesh}
    data::Dict{Symbol, Any}
end
export NativeMesh

Base.call{T <: HomogenousMesh}(::Type{NativeMesh}, m::T) = NativeMesh{T}(m)
function Base.call{T <: HomogenousMesh}(MT::Type{NativeMesh{T}}, m::T)
    result = Dict{Symbol, Any}()
    attribs = attributes(m)
    @materialize! vertices, faces = attribs
    result[:vertices]   = GLBuffer(vertices)
    result[:faces]      = indexbuffer(faces)
    for (field, val) in attribs
        if field in [:texturecoordinates, :normals, :attribute_id]
            result[field] = GLBuffer(val)
        else
            result[field] = Texture(val)
        end
    end
    MT(result)
end
