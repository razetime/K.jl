module K

module Tokenize

import Automa
import Automa.RegExp: @re_str

re = Automa.RegExp

colon    = re":"
adverb   = re"'" | re"/" | re"\\" | re"':" | re"/:" | re"\\:"
verb1    = colon | re"[\+\-*%!&\|<>=~,^#_\\$?@\.]"
verb     = verb1 | (verb1 * colon)
name     = re"[a-zA-Z]+[a-zA-Z0-9]*"
backq    = re"`"
symbol   = backq | (backq * name)
int      = re"0N" | re"\-?[0-9]+"
bitmask  = re"[01]+b"
float0   = re"\-?[0-9]+\.[0-9]*"
exp      = re"[eE][-+]?[0-9]+"
float    = re"0n" | re"0w" | re"-0w" | float0 | ((float0 | int) * exp)
str      = re.cat('"', re.rep(re"[^\"]" | re.cat("\\\"")), '"')
lparen   = re"\("
rparen   = re"\)"
lbracket = re"\["
rbracket = re"\]"
lbrace   = re"{"
rbrace   = re"}"
space    = re" +"
newline  = re"\n+"
semi     = re";"

tokenizer = Automa.compile(
  float    => :(emitnumber(:float)),
  int      => :(emitnumber(:int)),
  bitmask  => :(emitnumber(:bitmask)),
  name     => :(emit(:name)),
  symbol   => :(emit(:symbol)),
  verb     => :(emit(:verb)),
  adverb   => :(emit(:adverb)),
  lparen   => :(emit(:lparen)),
  rparen   => :(emit(:rparen)),
  lbracket => :(emit(:lbracket)),
  rbracket => :(emit(:rbracket)),
  lbrace   => :(emit(:lbrace)),
  rbrace   => :(emit(:rbrace)),
  semi     => :(emit(:semi)),
  str      => :(emitstr()),
  space    => :(markspace()),
  newline  => :(emit(:newline)),
)

context = Automa.CodeGenContext()

Token = Tuple{Symbol,String}

keepneg(tok) =
  tok===:adverb||
  tok===:verb||
  tok===:lparen||
  tok===:lbracket||
  tok===:lbrace||
  tok===:lsemi||
  tok===:newline

@eval function tokenize(data::String)::Vector{Token}
  $(Automa.generate_init_code(context, tokenizer))
  p_end = p_eof = sizeof(data)
  toks = Token[]
  space = nothing
  markspace() = (space = te)
  emit(kind) = push!(toks, (kind, data[ts:te]))
  emitstr() = begin
    str = data[ts+1:te-1]
    str = replace(str,
                  "\\0" => "\0",
                  "\\n" => "\n",
                  "\\t" => "\t",
                  "\\r" => "\r",
                  "\\\\" => "\\",
                  "\\\"" => "\"")
    push!(toks, (:str, str))
  end
  emitnumber(kind) =
    begin
      num = data[ts:te]
      if num[1]=='-' && space!=(ts-1) && !isempty(toks) && !keepneg(toks[end][1])
        push!(toks, (:verb, "-"))
        push!(toks, (kind, num[2:end]))
      else
        push!(toks, (kind, num))
      end
    end
  while p ≤ p_eof && cs > 0
    $(Automa.generate_exec_code(context, tokenizer))
  end
  if cs < 0 || te < ts
    error("failed to tokenize")
  end
  push!(toks, (:eof, "␀"))
  return toks
end

end

int_null = typemin(Int64)
float_null = NaN
any_null = []
char_null = ' '
symbol_null = Symbol("")

module Parse
import ..Tokenize: Token

abstract type Syntax end

struct Node <: Syntax
  type::Symbol
  body::Vector{Syntax}
end

struct Lit <: Syntax
  v::Union{Int64,Float64,Symbol,String}
end

struct Name <: Syntax
  v::Symbol
  Name(v::Symbol) = new(v)
  Name(v::String) = new(Symbol(v))
end

struct Prim <: Syntax
  v::Symbol
  Prim(v::Symbol) = new(v)
  Prim(v::String) = new(Symbol(v))
end

isnoun(syn::Syntax) = !isverb(syn)
isverb(syn::Syntax) = syn isa Node && syn.type === :verb

import AbstractTrees

AbstractTrees.nodetype(node::Parse.Node) = node.type
AbstractTrees.children(node::Parse.Node) = node.body

function Base.show(io::IO, node::Parse.Node)
  compact = get(io, :compact, false)
  if compact; print(io, "Node($(node.type))")
  else; AbstractTrees.print_tree(io, node)
  end
end

mutable struct ParseContext
  tokens::Vector{Token}
  pos::Int64
end

peek(ctx::ParseContext) =
  ctx.pos <= length(ctx.tokens) ? begin
    tok = ctx.tokens[ctx.pos]
    tok[1]
  end :
    nothing
skip!(ctx::ParseContext) =
  ctx.pos += 1
consume!(ctx::ParseContext) =
  begin
    @assert ctx.pos <= length(ctx.tokens)
    tok = ctx.tokens[ctx.pos]
    ctx.pos += 1
    tok
  end

import ..Tokenize, ..int_null, ..float_null, ..symbol_null, ..char_null

function parse(data::String)
  tokens = Tokenize.tokenize(data)
  ctx = ParseContext(tokens, 1)
  node = Node(:seq, exprs(ctx))
  @assert peek(ctx) === :eof
  node
end

function exprs(ctx::ParseContext)
  es = Syntax[]
  while true
    e = expr(ctx)
    if e !== nothing
      push!(es, e)
    end
    next = peek(ctx)
    if next===:semi||next===:newline
      consume!(ctx)
    else
      return es
    end
  end
  es
end

function expr(ctx::ParseContext)
  t = term(ctx)
  if t === nothing
    nothing
  elseif isverb(t)
    a = expr(ctx)
    if a !== nothing
      Node(:app, [t, Lit(1), a])
    else
      t
    end
  elseif isnoun(t)
    ve = expr(ctx)
    if ve !== nothing
      if ve isa Node &&
         ve.type === :app &&
         length(ve.body) == 3 &&
         ve.body[1] isa Node && ve.body[1].type === :verb
        v, _, x = ve.body
        Node(:app, [v, Lit(2), t, x])
      elseif ve isa Node && ve.type === :verb
        Node(:app, [ve, Lit(2), t])
      else
        Node(:app, [t, Lit(1), ve])
      end
    else
      t
    end
  elseif peek(ctx) === :eof
    nothing
  else
    @assert false
  end
end

function number0(ctx::ParseContext)
  tok, value = consume!(ctx)
  value =
    if tok === :int
      if value=="0N"
        int_null
      else
        Base.parse(Int64, value)
      end
    elseif tok === :float
      if value=="0w"
        Inf
      elseif value=="-0w"
        -Inf
      elseif value=="0n"
        float_null
      else
        Base.parse(Float64, value)
      end
    else
      @assert false
    end
  Lit(value)
end

function number(ctx::ParseContext)
  syn = number0(ctx)
  next = peek(ctx)
  if next === :int || next === :float
    syn = Node(:seq, [syn])
    while true
      push!(syn.body, number0(ctx))
      next = peek(ctx)
      next === :int || next === :float || break
    end
  end
  syn
end

function symbol0(ctx)
  tok, value = consume!(ctx)
  Lit(Symbol(value[2:end]))
end

function symbol(ctx::ParseContext)
  syn = symbol0(ctx)
  next = peek(ctx)
  if next === :symbol
    syn = Node(:seq, [syn])
    while true
      push!(syn.body, symbol0(ctx))
      next = peek(ctx)
      next === :symbol || break
    end
  end
  syn
end

function term(ctx::ParseContext)
  next = peek(ctx)
  t = 
    if next === :verb
      _, value = consume!(ctx)
      adverb(Node(:verb, [Prim(value)]), ctx)
    elseif next === :name
      _, value = consume!(ctx)
      maybe_adverb(Name(value), ctx)
    elseif next === :int || next === :float
      syn = number(ctx)
      maybe_adverb(syn, ctx)
    elseif next === :symbol
      syn = symbol(ctx)
      maybe_adverb(syn, ctx)
    elseif next === :bitmask
      _, value = consume!(ctx)
      value = Lit.(Base.parse.(Int64, collect(value[1:end-1])))
      syn = length(value) == 1 ? value[1] : Node(:seq, value)
      maybe_adverb(syn, ctx)
    elseif next === :str
      _, value = consume!(ctx)
      maybe_adverb(Lit(value), ctx)
    elseif next === :lbrace
      consume!(ctx)
      es = exprs(ctx)
      @assert peek(ctx) === :rbrace
      consume!(ctx)
      maybe_adverb(Node(:fun, es), ctx)
    elseif next === :lparen
      consume!(ctx)
      es = exprs(ctx)
      @assert peek(ctx) === :rparen
      consume!(ctx)
      syn = length(es) == 1 ? es[1] : Node(:seq, es)
      maybe_adverb(syn, ctx)
    else
      nothing
    end
  if t !== nothing
    app(t, ctx)
  else
    t
  end
end

function app(t, ctx::ParseContext)
  while peek(ctx) === :lbracket
    consume!(ctx)
    es = exprs(ctx)
    @assert peek(ctx) === :rbracket
    consume!(ctx)
    t = Node(:app, [t, Lit(max(1, length(es))), es...])
  end
  t
end

function adverb(verb, ctx::ParseContext)
  while peek(ctx) === :adverb
    _, value = consume!(ctx)
    push!(verb.body, Prim(value))
  end
  verb
end

function maybe_adverb(noun, ctx::ParseContext)
  if peek(ctx) === :adverb
    adverb(Node(:verb, [noun]), ctx)
  else
    noun
  end
end

end

module Runtime

import ..int_null, ..float_null, ..any_null

struct PFunction
  f::Function
  args::Tuple
  arity::Int
end
(s::PFunction)(args...) = s.f(s.args..., args...)
Base.show(io::IO, s::PFunction) = print(io, "*$(s.arity)-kfun*")

arity(f::Function) =
  begin
    monad,dyad,arity = false,false,0
    for m in methods(f)
      marity = m.nargs - 1
      monad,dyad = monad||marity==1,dyad||marity==2
      if marity!=1&&marity!=2
        @assert arity==0 || arity==marity "invalid arity"
        arity = marity
      end
    end
        if dyad       &&arity!=0; @assert false "invalid arity"
    elseif       monad&&arity!=0; @assert false "invalid arity"
    elseif dyad&&monad          ; [1,2]
    elseif dyad                 ; [2]
    elseif       monad          ; [1]
    elseif              arity!=0; [arity]
    else                        ; @assert false "invalid arity"
    end
  end
arity(f::PFunction) = [f.arity]

papp(f::Function, args, narr) =
  PFunction(f, args, narr)
papp(f::PFunction, args, narr) =
  PFunction(f.f, (f.args..., args...), narr)

app(f::Union{Function, PFunction}, args...) =
  begin
    flen, alen = arity(f), length(args)
    if alen in flen; f(args...)
    elseif flen[1] > alen; papp(f, args, flen[1] - alen)
    else; @assert false "arity error"
    end
  end

app(d::AbstractDict, key) = dictapp0(d, key)
app(d::AbstractDict{K}, key::K) where K = dictapp0(d, key)
app(d::AbstractDict, key::Vector) = app.(Ref(d), key)

dictapp0(d::AbstractDict, key) =
  begin
    v = get(d, key, nothing)
    if v === nothing
      v = null(eltype(typeof(d)).types[2])
    end
    v
  end

replicate(v, n) =
  reduce(vcat, fill.(v, n))

identity(f) =
  if f === kadd; 0
  elseif f === ksub; 0
  elseif f === kmul; 1
  elseif f === kdiv; 1
  elseif f === kand; 0
  elseif f === kor; 0
  else; Char[]
  end


isequal(x, y) = false
isequal(x::T, y::T) where T = x == y
isequal(x::Float64, y::Float64) = x === y # 1=0n~0n
isequal(x::Vector{T}, y::Vector{T}) where T =
  begin
    len = length(x)
    if len != length(y); return false end
    @inbounds for i in 1:len
      if !isequal(x[i], y[i]); return false end
    end
    return true
  end
isequal(x::AbstractDict{K,V}, y::AbstractDict{K,V}) where {K,V} =
  if length(x) != length(y); return false
  else
    for (xe, ye) in zip(x, y)
      if !isequal(xe.first, ye.first) ||
         !isequal(xe.second, ye.second)
        return false
      end
    end
    return true
  end

import Base: <, <=, ==, convert, length, isempty, iterate, delete!,
                 show, dump, empty!, getindex, setindex!, get, get!,
                 in, haskey, keys, merge, copy, cat,
                 push!, pop!, popfirst!, insert!,
                 union!, delete!, empty, sizehint!,
                 hash,
                 map, map!, reverse,
                 first, last, eltype, getkey, values, sum,
                 merge, merge!, lt, Ordering, ForwardOrdering, Forward,
                 ReverseOrdering, Reverse, Lt,
                 isless,
                 union, intersect, symdiff, setdiff, setdiff!, issubset,
                 searchsortedfirst, searchsortedlast, in,
                 filter, filter!, ValueIterator, eachindex, keytype,
                 valtype, lastindex, nextind,
                 copymutable, emptymutable, dict_with_eltype
include("dict_support.jl")
include("ordered_dict.jl")


isequal(x::OrderedDict{K,V}, y::OrderedDict{K,V}) where {K,V} =
  begin
    len = length(x.keys)
    if len != length(y.keys); return 0 end
    @inbounds for i in 1:len
      if !isequal(x.keys[i], y.keys[i]) ||
         !isequal(x.vals[i], y.vals[i])
        return false
      end
    end
    return true
  end

import ..float_null, ..int_null, ..symbol_null, ..char_null, ..any_null

null(::Type{Float64}) = float_null
null(::Type{Int64}) = int_null
null(::Type{Symbol}) = symbol_null
null(::Type{Char}) = char_null
# See https://chat.stackexchange.com/transcript/message/58631508#58631508 for a
# reasoning to return "" (an empty string).
null(::Type{Any}) = any_null

macro todo(msg)
  quote
    @assert false "todo: $($msg)"
  end
end

# verbs

macro dyad4char(f)
  f = esc(f)
  quote
    $f(x::Char, y) = $f(Int(x), y)
    $f(x, y::Char) = $f(x, Int(y))
    $f(x::Char, y::Char) = $f(Int(x), Int(y))
  end
end

macro dyad4vector(f)
  f = esc(f)
  quote
    $f(x::Vector, y) = $f.(x, y)
    $f(x, y::Vector) = $f.(x, y)
    $f(x::Vector, y::Vector) =
      (@assert length(x) == length(y); $f.(x, y))
  end
end

macro monad4dict(f)
  f = esc(f)
  quote
    $f(x::AbstractDict) = OrderedDict(zip(keys(x), $f.(values(x))))
  end
end

macro dyad4dict(f, V=nothing)
  f = esc(f)
  V = esc(V)
  quote
    $f(x::AbstractDict, y) = OrderedDict(zip(keys(x), $f.(values(x), y)))
    $f(x, y::AbstractDict) = OrderedDict(zip(keys(y), $f.(x, values(y))))
    $f(x::AbstractDict, y::Vector) =
      begin
        @assert length(x) == length(y)
        vals = $f.(values(x), y)
        OrderedDict(zip(keys(x), vals))
      end
    $f(x::Vector, y::AbstractDict) =
      begin
        @assert length(x) == length(y)
        vals = $f.(x, values(y))
        OrderedDict(zip(keys(y), vals))
      end
    $f(x::AbstractDict, y::AbstractDict) =
      begin
        K = promote_type(keytype(x), keytype(y))
        V = $V
        if V === nothing
          V = promote_type(valtype(x), valtype(y))
        end
        x = OrderedDict{K,V}(x)
        for (k, v) in y
          x[k] = $f(haskey(x, k) ? x[k] : identity($f), v)
        end
        x
      end
  end
end

# :: x
kself(x) = x

# : right
kright(x, y) = x

# + x
kflip(x) = [[x]]
kflip(x::Vector) =
  begin
    if isempty(x); return [x] end
    y = []
    leading = findfirst(xe -> xe isa Vector, x)
    leading = leading === nothing ? x[1] : x[leading]
    len = length(leading)
    for i in 1:len
      push!(y, [xe isa Vector ? xe[i] : xe for xe in x])
    end
    y
  end
kflip(::AbstractDict) = @todo "+d should produce a table"

# x + y
kadd(x, y) = x + y
@dyad4char(kadd)
@dyad4vector(kadd)
@dyad4dict(kadd)

# - x
kneg(x) = -x
kneg(x::Char) = -Int(x)
kneg(x::Vector) = kneg.(x)
@monad4dict(kneg)

# x - y
ksub(x, y) = x - y
@dyad4char(ksub)
@dyad4vector(ksub)
@dyad4dict(ksub)

# * x
kfirst(x) = x
kfirst(x::Vector) = isempty(x) ? null(eltype(x)) : (@inbounds x[1])
kfirst(x::AbstractDict) = isempty(x) ? null(eltype(x)) : first(x).second

# x * y
kmul(x, y) = x * y
@dyad4char(kmul)
@dyad4vector(kmul)
@dyad4dict(kmul)

# %N square root
ksqrt(x) = x<0 ? -0.0 : sqrt(x)
ksqrt(x::Char) = sqrt(Int(x))
ksqrt(x::Vector) = ksqrt.(x)
@monad4dict(ksqrt)

# x % y
kdiv(x, y) = x / y
@dyad4char(kdiv)
@dyad4vector(kdiv)
@dyad4dict(kdiv, Float64)

# ! i enum
kenum(x::Int64) =
  collect(x < 0 ? (x:-1) : (0:(x - 1)))

# ! I odometer
kenum(x::Vector) =
  begin
    rown = length(x)
    if rown==0; Any[]
    elseif rown==1; [collect(0:x[1]-1)]
    else
      coln = prod(x)
      if coln==0
        [Int64[] for _ in 1:rown]
      else
        o = Vector{Vector{Int64}}(undef, rown)
        repn = 1
        for (rowi, n) in enumerate(x)
          row = 0:n-1
          row = replicate(row, coln ÷ n ÷ repn)
          row = repeat(row, repn)
          o[rowi] = row
          repn = repn * n
        end
        o
      end
    end
  end
# !d keys
kenum(x::AbstractDict) = collect(keys(x))

# i!N mod / div
kmod(x::Int64, y) =
  x==0 ? y : x<0 ? Int(div(y,-x,RoundDown)) : rem(y,x,RoundDown)
kmod(x::Int64, y::Char) = kmod(x, Int(y))
kmod(x::Char, y::Int64) = kmod(Int(x), y)
kmod(x::Char, y::Char) = kmod(Int(x), Int(y))
kmod(x::Int64, y::Vector) = kmod.(x, y)
kmod(x::Char, y::AbstractDict) = kmod(Int(x), y)
kmod(x::Int64, y::AbstractDict) = OrderedDict(zip(keys(y), kmod.(x, values(y))))

# x!y dict
kmod(x, y) = OrderedDict(x => y)
kmod(x::Vector, y) = isempty(x) ? OrderedDict() : OrderedDict(x .=> y)
kmod(x, y::Vector) = isempty(y) ? OrderedDict() : OrderedDict(x => y[end])
kmod(x::Vector, y::Vector) =
  (@assert length(x) == length(y); OrderedDict(zip(x, y)))

# &I where
kwhere(x::Int64) = fill(0, x)
kwhere(x::Vector{Int64}) = replicate(0:length(x)-1, x)

# N&N min/and
kand(x, y) = min(x, y)
@dyad4char(kand)
@dyad4vector(kand)
@dyad4dict(kand)

# |x reverse
krev(x) = x
krev(x::Vector) = reverse(x)
krev(x::AbstractDict) = OrderedDict(reverse(collect(x)))

# N|N max/or
kor(x, y) = max(x, y)
@dyad4char(kor)
@dyad4vector(kor)
@dyad4dict(kor)

# ~x not
knot(x::Float64) = Int(x == 0.0)
knot(x::Int64) = Int(x == 0.0)
knot(x::Char) = Int(x == '\0')
knot(x::Symbol) = Int(x == symbol_null)
knot(x::Union{Function,PFunction}) = Int(x == kself)
knot(x::Vector) = knot.(x)
@monad4dict(knot)

# x~y match
kmatch(x, y) = Int(hash(x)===hash(y)&&isequal(x, y))

# =i unit matrix
kgroup(x::Int64) =
  begin
    m = Vector{Vector{Int64}}(undef, x)
    for i in 1:x
      m[i] = zeros(Int64, x)
      m[i][i] = 1
    end
    m
  end

# =X group
kgroup(x::Vector) =
  begin
    g = OrderedDict{eltype(x),Vector{Int64}}()
    allocg = Vector{Int64}
    # TODO: this is not correct right now as OrderedDict uses isequal and not
    # kmatch as it should be.
    for (n, xe) in enumerate(x)
      push!(get!(allocg, g, xe), n - 1)
    end
    g
  end

# x=y eq
keq(x, y) = x == y
@dyad4char(keq)
@dyad4vector(keq)
@dyad4dict(keq)

# ,x enlist
kenlist(x) = [x]

# x,y concat
kconcat(x, y) = [x, y]
kconcat(x, y::Vector) = [x, y...]
kconcat(x::Vector, y) = [x..., y]
kconcat(x::Vector, y::Vector) = vcat(x, y)
kconcat(x::AbstractDict, y::AbstractDict) = merge(x, y)

# ^x null
knull(x::Int64) = x == int_null
knull(x::Float64) = x === float_null
knull(x::Symbol) = x === symbol_null
knull(x::Char) = x === char_null
knull(x::Vector) = knull.(x)
@monad4dict(knull)

# a^y fill
kfill(x::Union{Number,Char,Symbol}, y) =
  y == int_null ||
  y === float_null ||
  y == symbol_null ||
  y == char_null ||
  y == any_null ?
  x : y
kfill(x::Union{Number,Char,Symbol}, y::Vector) = kfill.(x, y)
kfill(x::Union{Number,Char,Symbol}, y::AbstractDict) =
  OrderedDict(zip(keys(y), kfill.(x, values(y))))

# X^y without
kfill(x::Vector, y) =
  filter(x -> !(hash(x)===hash(y)&&isequal(x, y)), x)
kfill(x::Vector, y::Vector) =
  begin
    mask = OrderedDict(y .=> true)
    filter(x -> !haskey(mask, x), x)
  end

# #x length
klen(x) = 1
klen(x::Vector) = length(x)
klen(x::AbstractDict) = length(x)

# i#y reshape
kreshape(x::Int64, y) = kreshape(x, [y])
kreshape(x::Int64, y::Vector) =
  begin
    if x == 0; return empty(y) end
    it, len = x>0 ? (y, x) : (Iterators.reverse(y), -x)
    collect(Iterators.take(Iterators.cycle(it), len))
  end

# I#y reshape
kreshape(x::Vector, y) = kreshape(x, [y])
kreshape(x::Vector, y::Vector) = 
  length(x) == 0 ?
    Any[] :
    kreshape0(x, 1, Iterators.Stateful(Iterators.cycle(y)))
kreshape0(x, idx, it) =
  begin
    @assert x[idx] >= 0
    length(x) == idx ?
      collect(Iterators.take(it, x[idx])) :
      [kreshape0(x, idx+1, it) for _ in 1:x[idx]]
  end

# f#y replicate
kreshape(x::Union{Function,PFunction}, y) = 
  replicate(y, x(y))

# x#d take
kreshape(x::Vector, y::AbstractDict) = 
  OrderedDict(zip(x, dictapp0.(Ref(y), x)))

# _n floor
kfloor(x::Union{Int64, Float64}) = floor(x)

# _c lowercase
kfloor(x::Union{Char,Vector{Char}}) = lowercase(x)

kfloor(x::Vector) = kfloor.(x)
@monad4dict(kfloor)

# i_Y drop
kdrop(x::Int64, y::Vector) =
  if x == 0; y elseif x > 0; y[x + 1:end] else; y[1:end + x] end
kdrop(x::Int64, y::AbstractDict) =
  begin
    ks = kdrop(x, collect(keys(y)))
    vs = kdrop(x, collect(values(y)))
    OrderedDict(zip(ks, vs))
  end

# I_Y cut
kdrop(x::Vector{Int64}, y::Vector) =
  begin
    if isempty(y); return Any[] end
    o = Vector{eltype(y)}[]
    previ = -1
    @inbounds for i in x
      if previ != -1
        @assert i >= previ
        push!(o, y[previ + 1:i])
      end
      previ = i
    end
    push!(o, y[previ + 1:end])
    o
  end

# f_Y weed out
kdrop(x::Union{Function,PFunction}, y::Vector) =
  filter(e -> !x(e), y)

# X_i delete
kdrop(x::Vector, y::Int64) =
  y < 0 || y >= length(x) ? x : deleteat!(copy(x), [y+1])

# $x string
kstring(x::Union{Int64,Float64,Symbol}) = collect(string(x))
kstring(x::Vector) = kstring.(x)
@monad4dict(kstring)

# i$C pad
kcast(x::Int64, y::Vector{Char}) =
  begin
    if x == 0; return Char[] end
    len = length(y)
    absx = abs(x)
    if len == absx; y
    elseif len > absx
      x > 0 ?
        y[1:x] :
        y[-x:end]
    else
      x > 0 ?
        vcat(y, repeat(fill(' '), absx - len)) :
        vcat(repeat(fill(' '), absx - len), y)
    end
  end

# adverbs

function kfold(f)
  kfoldf(x) = isempty(x) ? identity(f) : foldl(f, x)
  kfoldf(x::AbstractDict) = kfoldf(values(x))
  kfoldf(x, y) = foldl(f, y, init=x)
end

end

module Compile
import ..Parse: Syntax, Node, Lit, Name, Prim, parse
import ..Runtime

verbs = Dict(
             (      :(::),  1) => Runtime.kself,
             (       :(:),  2) => Runtime.kright,
             (         :+,  1) => Runtime.kflip,
             (         :+,  2) => Runtime.kadd,
             (         :-,  1) => Runtime.kneg,
             (         :-,  2) => Runtime.ksub,
             (         :*,  1) => Runtime.kfirst,
             (         :*,  2) => Runtime.kmul,
             (         :%,  1) => Runtime.ksqrt,
             (         :%,  2) => Runtime.kdiv,
             (       :(!),  1) => Runtime.kenum,
             (       :(!),  2) => Runtime.kmod,
             (       :(&),  1) => Runtime.kwhere,
             (       :(&),  2) => Runtime.kand,
             (       :(|),  1) => Runtime.krev,
             (       :(|),  2) => Runtime.kor,
             (       :(~),  1) => Runtime.knot,
             (       :(~),  2) => Runtime.kmatch,
             (       :(=),  1) => Runtime.kgroup,
             (       :(=),  2) => Runtime.keq,
             ( Symbol(','), 1) => Runtime.kenlist,
             ( Symbol(','), 2) => Runtime.kconcat,
             (          :^, 1) => Runtime.knull,
             (          :^, 2) => Runtime.kfill,
             ( Symbol('#'), 1) => Runtime.klen,
             ( Symbol('#'), 2) => Runtime.kreshape,
             (       :(_),  1) => Runtime.kfloor,
             (       :(_),  2) => Runtime.kdrop,
             (       :($),  1) => Runtime.kstring,
            )

adverbs = Dict(
               :(/) => Runtime.kfold,
              )

compile(syn::Node) =
  quote $(map(compile1, syn.body)...) end
compile(str::String) =
  compile(parse(str))

compile1(syn::Node) =
  if syn.type === :seq
    es = map(compile1, syn.body)
    :([$(es...)])
  elseif syn.type === :app
    f, arity, args... = syn.body
    args = map(compile1, args)
    if isempty(args); args = [Runtime.kself] end
    if f isa Node && f.type===:verb && length(f.body)===1 &&
        f.body[1] isa Prim && f.body[1].v===:(:) &&
        arity.v==2 && args[1] isa Symbol
      # assignment `n:x`
      name,rhs=args[1],args[2]
      :($name = $rhs)
    elseif f isa Node && f.type===:verb && length(f.body)===1 &&
        f.body[1] isa Prim && f.body[1].v===:(:) &&
        arity.v==1
      # return `:x`
      rhs=args[1]
      :(return $rhs)
    elseif f isa Node && f.type===:verb
      @assert arity.v == 1 || arity.v === 2
      f = compilefun(f, arity.v)
      compileapp(f, args)
    elseif f isa Node && f.type===:fun
      @assert arity.v === length(args)
      f = eval(compile1(f)) # as this is a function, we can eval it now
      compileapp(f, args)
    else # generic case
      @assert arity.v === length(args)
      f = compile1(f)
      compileapp(f, args)
    end
  elseif syn.type === :fun
    x,y,z=implicitargs(syn.body)
    body = map(compile1, syn.body)
    if z
      :((x, y, z) -> $(body...))
    elseif y
      :((x, y) -> $(body...))
    elseif x
      :((x) -> $(body...))
    else
      :((_) -> $(body...))
    end
  elseif syn.type===:verb
    hasavs = length(syn.body) > 1
    prefer_arity = hasavs ? 1 : 2
    :($(compilefun(syn, prefer_arity)))
  end

compile1(syn::Name) =
  :($(syn.v))

compile1(syn::Lit) =
  if syn.v isa String
    v = length(syn.v) == 1 ? syn.v[1] : collect(syn.v)
    :($v)
  elseif syn.v isa Symbol
    Meta.quot(syn.v)
  else
    syn.v
  end

compile1(syn::Prim) =
  :($(compilefun(syn, 2)))

compileapp(f, args) =
  :($(Runtime.app)($(f), $(args...)))

compileapp(f, args, arity) =
  let alen = length(args)
    if alen in arity
      :($f($(args...)))
    elseif alen < arity[1]
      :($(Runtime.papp)($f, $(tuple(args...)), $(arity[1] - alen)))
    else
      @assert false "invalid arity"
    end
  end

compileapp(f::Union{Function,Runtime.PFunction}, args) =
  compileapp(f, args, Runtime.arity(f))

compilefun(syn::Prim, prefer_arity::Int64) =
  begin
    f =
      if prefer_arity == 2
        f = get(verbs, (syn.v, 2), nothing)
        if f === nothing
          f = get(verbs, (syn.v, 1), nothing)
        end
        f
      elseif prefer_arity == 1
        f = get(verbs, (syn.v, 1), nothing)
      else; @assert false end
    get(verbs, (syn.v, prefer_arity), nothing)
    @assert f !== nothing "primitive is not implemented: $(syn.v) ($prefer_arity arity)"
    f
  end
compilefun(syn::Node, prefer_arity::Int64) =
  if syn.type===:verb
    f, avs... = syn.body
    f = compilefun(f, isempty(avs) ? prefer_arity : 2)
    for av in avs
      @assert av isa Prim
      makef = get(adverbs, av.v, nothing)
      @assert makef !== nothing "primitive is not implemented: $(av.v)"
      if f isa Expr
        f = :($makef($f))
      else
        f = makef(f)
      end
    end
    f
  else
    compile1(syn)
  end

implicitargs(syn::Name) =
  syn.v===:x,syn.v===:y,syn.v===:z
implicitargs(syn::Lit) =
  false,false,false
implicitargs(syn::Prim) =
  false,false,false
implicitargs(syn::Node) =
  if syn.type === :fun; false,false,false
  else; implicitargs(syn.body)
  end
implicitargs(syns::Vector{Syntax}) =
  begin
    x,y,z=false,false,false
    for syn in syns
      x0,y0,z0=implicitargs(syn)
      x,y,z=x||x0,y||y0,z||z0
      if x&&y&&z; break end
    end
    x,y,z
  end

end

tokenize = Tokenize.tokenize
parse = Parse.parse
compile = Compile.compile

k(k::String, mod::Module) =
  begin
    syn = parse(k)
    # @info "syn" syn
    jlcode = compile(syn)
    # @info "jlcode" jlcode
    mod.eval(jlcode)
  end

macro k_str(code); k(code, __module__) end

module Repl
using ReplMaker, REPL

import ..compile, ..parse

function init()
  # show_function(io::IO, mime::MIME"text/plain", x) = print(io, x)
  function valid_input_checker(ps::REPL.LineEdit.PromptState)
    s = REPL.LineEdit.input_string(ps)
    try; parse(s); true
    catch e; false end
  end
  function run(code::String)
    jlcode = compile(code)
    Main.eval(jlcode)
  end
  initrepl(run,
           prompt_text="  ",
           prompt_color=:blue, 
           # show_function=show_function,
           valid_input_checker=valid_input_checker,
           startup_text=true,
           start_key='\\', 
           mode_name="k")
  nothing
end

function __init__()
  if isdefined(Base, :active_repl)
    init()
  else
    atreplinit() do repl
      init()
    end
  end
end
end

1

export k
export @k_str

end # module
