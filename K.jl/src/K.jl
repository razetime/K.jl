module K

module Tokenize

export Token, tokenize

import Automa
import Automa.RegExp: @re_str

re = Automa.RegExp

colon    = re":"
adverb   = re"'" | re"/" | re"\\" | re"':" | re"/:" | re"\\:"
verb1    = colon | re"[\+\-*%!&\|<>=~,^#_$?@\.]"
verb     = verb1 | (verb1 * colon)
id       = re"[a-zA-Z]+[a-zA-Z0-9]*"
name     = id * re.rep(re.cat('.', id))
backq    = re"`"
int      = re"0N" | re"\-?[0-9]+"
bitmask  = re"[01]+b"
float0   = re"\-?[0-9]+\.[0-9]*"
exp      = re"[eE][-+]?[0-9]+"
float    = re"-0n" | re"0n" | re"0w" | re"-0w" | float0 | ((float0 | int) * exp)
str      = re.cat('"', re.rep(re"[^\"]" | re.cat("\\\"")), '"')
symbol   = backq | (backq * id) | (backq * str)
lparen   = re"\("
rparen   = re"\)"
lbracket = re"\["
rbracket = re"\]"
lbrace   = re"{"
rbrace   = re"}"
space    = re" +"
comment  = re.rep1(space) * re"/[^\r\n]*"
newline  = re"\n+"
semi     = re";"

tokenizer = Automa.compile(
  comment  => :(),
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
  tok===:semi||
  tok===:newline

@eval function tokenize(data::AbstractString)::Vector{Token}
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

module Null
int_null = typemin(Int64)
float_null = NaN
char_null = ' '
symbol_null = Symbol("")
any_null = Char[]

null(::Type{Float64}) = float_null
null(::Type{Int64}) = int_null
null(::Type{Symbol}) = symbol_null
null(::Type{Char}) = char_null
# See https://chat.stackexchange.com/transcript/message/58631508#58631508 for a
# reasoning to return "" (an empty string).
null(::Type{Any}) = any_null

isnull(x::Int64) = x == int_null
isnull(x::Float64) = x === float_null
isnull(x::Symbol) = x === symbol_null
isnull(x::Char) = x === char_null
end

module Syntax

export Syn,Seq,LSeq,App,Fun,Train,LBind,Lit,Verb,Adverb,Id,Omit

abstract type Syn end

struct Lit <: Syn
  v::Union{Int64,Float64,Symbol,String}
end

struct Seq <: Syn
  body::Vector{Syn}
end

struct LSeq <: Syn
  body::Vector{Lit}
end

struct App <: Syn
  head::Syn
  args::Vector{Syn}
  App(head::Syn, args::Syn...) = new(head, collect(args))
end

struct Train <: Syn
  head::Syn
  next::Syn
end

struct LBind <: Syn
  v::Syn
  arg::Syn
end

struct Fun <: Syn
  body::Vector{Syn}
end

struct Verb <: Syn
  v::Symbol
  Verb(v::String) = new(Symbol(v))
  Verb(v::Char) = new(Symbol(v))
end

struct Adverb <: Syn
  v::Symbol
  arg::Syn
  Adverb(v::Symbol, arg) = new(v, arg)
  Adverb(v::String, arg) = new(Symbol(v), arg)
end

struct Id <: Syn
  v::Symbol
  Id(v::Symbol) = new(v)
  Id(v::String) = new(Symbol(v))
end

struct Omit <: Syn
end

verbs = collect(raw"+-*%!&|<>=~,^#_$?@.")

monadics, dyadics =
  Verb.(map(v -> v * ":", verbs)), Verb.(verbs) 
right = Verb(":")
self = Verb("::")
dyadics2monadics = Dict(zip(dyadics, monadics))
for v in [right, self]; dyadics2monadics[v] = v end

monadics_av = Set(Symbol.(['\'']))

import AbstractTrees

AbstractTrees.nodetype(s::Syn) = nameof(typeof(s))
AbstractTrees.children(s::Syn) = []
AbstractTrees.children(s::Union{LSeq,Seq,Fun}) = s.body
AbstractTrees.children(s::App) = [s.head, s.args...]
AbstractTrees.children(s::Train) = [s.head, s.next]
AbstractTrees.children(s::LBind) = [s.v, s.arg]
AbstractTrees.children(s::Adverb) = [s.arg]

print_compact(io::IO, s::Syn) =
  print(io, nameof(typeof(s)))
print_compact(io::IO, s::Union{Lit,Id,Verb,Adverb}) =
  print(io, "$(nameof(typeof(s)))($(repr("text/plain", s.v)))")

function Base.show(io::IO, s::Syn)
  compact = get(io, :compact, false)
  if compact; print_compact(io, s)
  else; AbstractTrees.print_tree(io, s; maxdepth=6)
  end
end
end

module Parse

using ..Syntax, ..Tokenize
import ..Null

export parse

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
    @assert ctx.pos <= length(ctx.tokens);
    tok = ctx.tokens[ctx.pos]; ctx.pos += 1; tok
  end
consume!(ctx::ParseContext, tok::Symbol) =
  (@assert peek(ctx) == tok "expected $tok got $(peek(ctx))"; consume!(ctx))

# grammar:  E:E;e|e e:nve|te| t:n|v v:tA|V n:t[E]|(E)|{E}|N
#                   f:vv|nv|nf|vf
function parse(data::AbstractString)
  tokens = tokenize(data)
  ctx = ParseContext(tokens, 1)
  node = Seq(exprs(ctx))
  @assert peek(ctx) === :eof "expected EOF but got $(peek(ctx))"
  node
end

function exprs(ctx::ParseContext; parse_omit::Bool=false)
  es = Syn[]
  seen_semi = true
  while true
    e = expr(ctx)
    if e !== nothing
      push!(es, e)
      seen_semi = false
      continue
    end
    next = peek(ctx)
    if next === :semi
      _, value = consume!(ctx)
      seen_semi && parse_omit && push!(es, Omit())
      seen_semi = true
    elseif next === :newline
      seen_semi = false
      consume!(ctx)
    else
      seen_semi && parse_omit && length(es) > 0 && push!(es, Omit())
      return es
    end
  end
  es
end

struct N; syn::Syn end
struct V; syn::Syn end

function expr(ctx::ParseContext)::Union{Syn,Nothing}
  ts = Union{N,V}[]
  while true
    t = term(ctx)
    t !== nothing ? push!(ts, t) : break
  end
  isempty(ts) && return
  e = pop!(ts)
  while !isempty(ts)
    if length(ts) > 1 && ts[end] isa V && ts[end-1] isa N
      v, n = pop!(ts), pop!(ts)
      e = e isa N || v.syn == Syntax.right ?
        N(App(v.syn, n.syn, e.syn)) : # nvn
        V(Train(LBind(v.syn, n.syn), e.syn)) # nvv
    elseif ts[end] isa V
      v = pop!(ts)
      e = e isa V && v.syn != Syntax.right ?
        V(Train(as_monadic(v.syn), e.syn)) : # vv
        N(App(as_monadic(v.syn), e.syn)) # vn
    elseif ts[end] isa N
      n = pop!(ts)
      e = e isa V ?
        V(e.syn isa Union{Adverb,Verb} ? # nv
          LBind(e.syn, n.syn) : 
          Train(n.syn, e.syn)) :
        N(App(as_monadic(n.syn), e.syn)) # nn
    end
  end
  e.syn
end

function term(ctx::ParseContext)::Union{N,V,Nothing}
  next = peek(ctx)
  t = 
    if next === :verb
      _, value = consume!(ctx)
      V(Verb(value))
    elseif next === :name
      _, value = consume!(ctx)
      N(Id(value))
    elseif next === :int || next === :float
      N(number(ctx))
    elseif next === :symbol
      N(symbol(ctx))
    elseif next === :bitmask
      _, value = consume!(ctx)
      value = Lit.(Base.parse.(Int64, collect(value[1:end-1])))
      N((length(value) == 1 ? value[1] : LSeq(value)))
    elseif next === :str
      _, value = consume!(ctx)
      N(Lit(value))
    elseif next === :lbrace
      consume!(ctx)
      es = exprs(ctx)
      consume!(ctx, :rbrace)
      N(Fun(es))
    elseif next === :lparen
      consume!(ctx)
      es = exprs(ctx)
      consume!(ctx, :rparen)
      N((length(es) == 1 ? es[1] : Seq(es)))
    else
      nothing
    end
  if t !== nothing
    while true
      next = peek(ctx)
      if next === :lbracket
        consume!(ctx)
        es = exprs(ctx, parse_omit=true)
        consume!(ctx, :rbracket)
        arity = max(1, length(es))
        t = N(App(arity==1 ? as_monadic(t.syn) : t.syn, es...))
      elseif next === :adverb
        _, val = consume!(ctx)
        t = V(Adverb(val, t.syn))
      else
        break
      end
    end
  end
  t
end

function number0(ctx::ParseContext)
  tok, value = consume!(ctx)
  value =
    if tok === :int
      if value=="0N"
        Null.null(Int64)
      else
        Base.parse(Int64, value)
      end
    elseif tok === :float
      if value=="0w"
        Inf
      elseif value=="-0w"
        -Inf
      elseif value=="0n"
        Null.null(Float64)
      elseif value=="-0n"
        -Null.null(Float64)
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
    syn = LSeq([syn])
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
  value = value[2:end]
  if isempty(value)
    Lit(Symbol(""))
  elseif value[1] == '"'
    Lit(Symbol(value[2:end-1]))
  else
    Lit(Symbol(value))
  end
end

function symbol(ctx::ParseContext)
  syn = symbol0(ctx)
  next = peek(ctx)
  if next === :symbol
    syn = LSeq([syn])
    while true
      push!(syn.body, symbol0(ctx))
      next = peek(ctx)
      next === :symbol || break
    end
  end
  syn
end

as_monadic(v) = v
as_monadic(v::Verb) =
  get(Syntax.dyadics2monadics, v, v)
as_monadic(v::Train) =
  Train(v.head, as_monadic(v.next))
as_monadic(v::Adverb) =
  v.v in Syntax.monadics_av ? Adverb(v.v, as_monadic(v.arg)) : v

end

module Runtime
import ..Null

# K-specific function types

abstract type AFun end

Arity = UnitRange{Int64} # TODO: Int8

KFun = Union{Function,AFun}

struct Fun{F<:KFun} <: AFun
  f::F
  arity::Arity
  Fun(f::KFun, arity::Arity) = new{typeof(f)}(f, arity)
  Fun(f::KFun, arity::Int64) = new{typeof(f)}(f, arity:arity)
end
(s::Fun)(args...) = s.f(args...)
arity(f::Fun)::Arity = f.arity
Base.promote_op(f::Fun, S::Type...) = Base.promote_op(f.f, S...)
Base.show(io::IO, s::Fun) = print(io, "*$(s.arity)-function*")

struct MFun{F<:KFun} <: AFun f::F end
@inline (s::MFun)(x) = s.f(x)
arity(f::MFun)::Arity = 1:1
Base.promote_op(f::MFun, S::Type...) = Base.promote_op(f.f, S...)
Base.show(io::IO, s::MFun) = print(io, "*mfunction*")

struct DFun{F<:KFun} <: AFun f::F end
@inline (s::DFun)(x, y) = s.f(x, y)
arity(f::DFun)::Arity = 2:2
Base.promote_op(f::DFun, S::Type...) = Base.promote_op(f.f, S...)
Base.show(io::IO, s::DFun) = print(io, "*dfunction*")

struct AppFun <: AFun end
arity(o::AppFun) = 2:8
Base.show(io::IO, s::AppFun) = print(io, "*app*")
Base.promote_op(::AppFun, V::Type{<:Vector}, I::Type{Vector}) =
  Base.promote_op(app, V, S)
Base.promote_op(::AppFun, F, S::Type) = Base.promote_op(F, S...)

struct PFun <: AFun
  f::KFun
  args::Tuple
  arity::Int64
  PFun(f, args, narr) =
    new(f, args, narr)
  PFun(f::PFun, args, narr) =
    new(f.f, (f.args..., args...), narr)
end
@inline (s::PFun)(args...) = s.f(s.args..., args...)
arity(f::PFun)::Arity = f.arity:f.arity
Base.show(io::IO, s::PFun) = print(io, "*$(s.arity)-pfunction*")
Base.promote_op(f::PFun, S::Type...) =
  Base.promote_op(f.f, map(typeof, f.args)..., S...)

struct P1Fun{F<:KFun,X} <: AFun
  f::F
  arg::X
  arity::Int64
end
(o::P1Fun)(x) = o.f(o.arg, x)
@inline (o::P1Fun)(x, args...) = o.f(o.arg, x, args...)
arity(o::P1Fun)::Arity = o.arity:o.arity
Base.show(io::IO, s::P1Fun) = print(io, "*$(s.arity)-pfunction*")
Base.promote_op(o::P1Fun, S::Type...) =
  Base.promote_op(o.f, typeof(o.arg), S...)

# TODO: make it work?
# arity(f::Function)::Arity =
#   begin
#     monad,dyad,triad,arity = false,false,false,0
#     for m in methods(f)
#       marity = m.nargs - 1
#       monad,dyad,triad = monad||marity==1,dyad||marity==2,triad||marity==3
#       if marity!=1&&marity!=2&&marity!=3
#         @assert arity==0 || arity==marity "invalid arity"
#         arity = marity
#       end
#     end
#         if              triad&&arity!=0; @assert false "invalid arity"
#     elseif        dyad       &&arity!=0; @assert false "invalid arity"
#     elseif monad             &&arity!=0; @assert false "invalid arity"
#     elseif monad&&dyad&&triad          ; 1:3
#     elseif monad      &&triad          ; @assert false "invalid arity"
#     elseif monad&&dyad                 ; 1:2
#     elseif        dyad&&triad          ; 2:3
#     elseif monad                       ; 1:1
#     elseif        dyad                 ; 2:2
#     elseif              triad          ; 3:3
#     elseif                     arity!=0; arity:arity
#     else                               ; @assert false "invalid arity"
#     end
#   end

# K-types

KAtom = Union{Float64,Int64,Symbol,Char}

replicate(v, n) =
  reduce(vcat, fill.(v, n))

tryidentity(@nospecialize(f), T::Type, @nospecialize(d)) =
  T != Any && hasmethod(f, (Type{T},)) ? f(T) : d

identity(f) =
  if f === kadd; 0
  elseif f === ksub; 0
  elseif f === kmul; 1
  elseif f === kdiv; 1
  elseif f === kand; typemax(Int64)
  elseif f === kor; typemin(Int64) + 1
  elseif f === kconcat; Any[]
  else; nothing
  end
identity(f, T::Type) =
  if f === kadd; tryidentity(zero, T, 0)
  elseif f === ksub; tryidentity(zero, T, 0)
  elseif f === kmul; tryidentity(one, T, 1)
  elseif f === kdiv; tryidentity(one, T, 1)
  elseif f === kand; tryidentity(typemax, T, identity(f))
  elseif f === kor
    hasmethod(one, (T,)) ? typemin(T) + one(T) : identity(f)
  elseif f === kconcat; T <: Vector ? eltype(T)[] : T[]
  else; nothing
  end
scanidentity(f, T::Type) =
  if f === kadd; tryidentity(zero, T, 0)
  elseif f === ksub; nothing
  elseif f === kmul; nothing
  elseif f === kdiv; nothing
  elseif f === kand; nothing
  elseif f === kor; nothing
  elseif f === kconcat; T <: Vector ? eltype(T)[] : T[]
  else; nothing
  end

isequal(x, y) = false
isequal(x::T, y::T) where T = x == y
isequal(x::Float64, y::Float64) = x === y # 1=0n~0n
isequal(x::Vector, y::Vector) where T =
  begin
    len = length(x)
    len != length(y) && return false
    @inbounds for i in 1:len
      !isequal(x[i], y[i]) && return false
    end
    return true
  end
isequal(x::AbstractDict{K,V}, y::AbstractDict{K,V}) where {K,V} =
  begin
    length(x) != length(y) && return false
    for (xe, ye) in zip(x, y)
      if !isequal(xe.first, ye.first) ||
         !isequal(xe.second, ye.second)
        return false
      end
    end
    return true
  end
  
isless(x, y) = x < y
isless(x::Char, y::Char) = isless(Int(x), Int(y))
isless(x::Char, y) = isless(Int(x), y)
isless(x, y::Char) = isless(x, Int(y))
isless(x::Vector, y) = true
isless(x, y::Vector) = false
isless(x::Vector, y::Vector) =
  begin
    for (xe, ye) in zip(x, y)
      isequal(xe, ye) ? continue : return isless(xe, ye)
    end
    return length(x) < length(y)
  end

# K dicts

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

# rank

non_urank = typemax(Int64)

rank(x) = 0
rank(x::Vector{T}) where T<:KAtom = 1
rank(x::Vector{Vector{T}}) where T<:KAtom = 2
rank(x::Vector) =
  begin
    if isempty(x)
      return 2 # 1 + rank(null(eltype(x)))
    else
      r = nothing
      for e in x
        r′ = rank(e)
        if r === nothing; r = r′
        elseif r !== r′; return non_urank end
      end
      1 + r
    end
  end

urank(x) = 0
urank(x::Vector{T}) where T<:KAtom = 1
urank(x::Vector) =
  begin
    if isempty(x)
      return 2 # 1 + rank(null(eltype(x)))
    else
      @inbounds 1 + rank(x[1])
    end
  end

outdex′(x) = Null.null(typeof(x))
outdex′(x::Vector) =
  isempty(x) ? Null.any_null : fill(outdex(x), length(x))

outdex(x) = outdex′(x)
outdex(x::Vector{T}) where T <: KAtom =
  Null.null(eltype(x))
outdex(x::Vector) =
  isempty(x) ? Null.any_null : begin
    @inbounds v = x[1]
    fill(outdex(v), length(v))
  end
outdex(x::AbstractDict) =
  isempty(x) ? Null.any_null : outdex′(first(x).second)

# application

macro papp(f, args)
  f, args = esc(f), esc(args)
  quote
    flen, alen = arity($f), length($args)
    if alen in flen; $f($args...)
    elseif alen < flen.start
      alen == 1 ?
        P1Fun($f, $args[1], flen[1] - alen) :
        PFun($f, $args, flen[1] - alen)
    else; @assert false "arity error" end
  end
end

app(o::MFun, x) = o.f(x)
@inline app(o::DFun, x) = P1Fun(o.f, x, 1)
@inline app(o::DFun, x, y) = o.f(x, y)
app(o::AppFun, f, args...) = @papp(f, args)
@inline app(o::AppFun, f::Vector, args...) = app(f, args...)
(o::AppFun)(f, args...) = @papp(f, args)
(o::AppFun)(f::Vector, args...) = app(f, args...)
(o::AppFun)(f::Vector{T}, v::Vector{I}) where {T,I} = app(f, v)
app(@nospecialize(f::KFun), args...) = @papp(f, args)

app(x::Vector, is...) =
  begin
    i, is... = is
    i === Colon() ?
      keach′(e -> app(e, is...), x) :
      i isa Vector || i isa AbstractDict ?
      keach′(e -> app(e, is...), app(x, i)) :
      app(app(x, i), is...)
  end
app(x::Vector, ::Colon) = x
app(x::Vector, is::Vector) = app.(Ref(x), is)
(app(x::Vector{T}, i::Int64)::T) where {T} =
  (v = get(x, i + 1, nothing); v === nothing ? outdex(x) : v)
(app(x::Vector{T}, is::Vector{Int64})::Vector{T}) where {T} =
  app.(Ref(x), is)
app(x::Vector, is::AbstractDict) =
  OrderedDict(zip(keys(is), app(x, collect(values(is)))))
Base.promote_op(app, T::Type{<:Vector}, I::Type{<:Vector}) = T
Base.promote_op(app, T::Type{<:Vector}, I::Type{Int64}) = eltype(T)

app(x::AbstractDict, is...) =
  begin
    k, is... = is
    krank, xrank = rank(k), urank(first(x).first)
    @assert krank >= xrank "rank error"
    k === Colon() ?
      keach′(e -> app(e, is...), x) :
      krank > xrank ?
      keach′(e -> app(e, is...),
             krank === non_urank ?
             app.(Ref(x), k) :
             dappX(x, krank - xrank, k)) :
      app(dapp(x, k), is...)
  end
app(x::AbstractDict, ::Colon) = x
app(x::AbstractDict, i) =
  i === kself ? x : begin
    xrank = urank(first(x).first)
    @assert xrank == 0 "rank error"
    dapp(x, i)
  end
app(x::AbstractDict, i::Vector) =
  begin
    xrank, irank = urank(first(x).first), rank(i)
    @assert xrank <= irank "rank error"
    xrank === irank ?
      dapp(x, i) :
      irank === non_urank ?
      app.(Ref(x), i) :
      dappX(x, irank - xrank, i)
  end
app(x::AbstractDict, i::AbstractDict) =
  OrderedDict(zip(keys(i), app(x, collect(values(i)))))

dapp(d::AbstractDict, key) =
  begin
    v = get(d, key, nothing)
    if v === nothing; v = outdex(d) end
    v
  end
dappX(d::AbstractDict, depth, key) =
  depth === 0 ? dapp(d, key) : dappX.(Ref(d), depth - 1, key)

# aux macro

macro todo(msg)
  quote
    @assert false "todo: $($msg)"
  end
end

macro dyad4char(f)
  f = esc(f)
  quote
    $f(x::Char, y::Number) = $f(Int(x), y)
    $f(x::Number, y::Char) = $f(x, Int(y))
    $f(x::Char, y::Char) = $f(Int(x), Int(y))
  end
end

macro dyad4vector(f)
  f = esc(f)
  quote
    $f(x::Vector, y) = $f.(x, y)
    $f(x, y::Vector) = $f.(x, y)
    $f(x::Vector, y::Vector) = (@assert length(x) == length(y); $f.(x, y))
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

# trains

struct Train <: AFun
  head::Any
  next::Any
end
# TODO: should we ask next for arity?
arity(::Train)::Arity = 1:2
(o::Train)(x) = app(o.head, app(o.next, x))
(o::Train)(x, y) = app(o.head, app(o.next, x, y))

# adverbs

macro adverb(name, arr)
  quote
    struct $(esc(name)) <: AFun; f::Any end
    # TODO: this is incorrect, each adverb should define its own promotion...
    Base.promote_op(f::$(esc(name)), S::Type...) = Base.promote_op(f.f, S...)
    $(esc(:arity))(::$(esc(name)))::Arity = $arr
  end
end

# fold

@adverb FoldM 1:2
@adverb FoldD 1:3

struct Join <: AFun
  s::Vector{Char}
end
arity(::Join)::Arity = 1:1

struct Decode{T} <: AFun
  b::T
end
arity(::Decode)::Arity = 1:1

# f/ converge
(o::FoldM)(x) =
  begin
    while true
      x′ = o.f(x)
      !(hash(x′) == hash(x) && isequal(x, x′)) || break
      x = x′
    end
    x
  end
# f f/ while
(o::FoldM)(x::KFun, y) =
  begin
    while Bool(x(y))
      y = o.f(y)
    end
    y
  end
# i f/ n-do
(o::FoldM)(x::Int64, y) =
  begin
    i = 0
    while i < x
      y = o.f(y)
      i = i + 1
    end
    y
  end

# F/ fold
(o::FoldD)(x) =
  isempty(x) ?
    identity(o.f, eltype(typeof(x))) :
    foldl(o.f, x)
# x F/ seeded /  10+/1 2 3 -> 16
(o::FoldD)(x, y) = foldl(o.f, y, init=x)
(o::FoldD)(x::AbstractDict) = o(values(x))
# F/[n;x;y] n-element of a recurrent series defined by F
(o::FoldD)(n, x, y) =
  begin
    @assert n >= 0
    while n >= 0; n, x, y = n - 1, app(o.f, x, y), x end
    x
  end

# C/ join
(o::Join)(x::Vector) =
  begin
    r = Char[]
    if isempty(x); return r end
    i, len = 1, length(x)
    while i <= len
      if i > 1; append!(r, o.s) end
      @inbounds append!(r, x[i])
      i = i + 1
    end
    r
  end
(o::Decode)(x::Vector{<:Number}) = decode1(o.b, x)

decode1(b::Int64, x::Vector{<:Number}) =
  begin
    r, lenx = 0, length(x)
    @inbounds for i in 0:lenx-1
      r = kadd(r, kmul(b^i, x[end-i]))
    end
    r
  end
decode1(b::Vector{Int64}, x::Vector{<:Number}) =
  begin
    lenx = length(x)
    @assert length(b) == lenx
    lenx == 0 && return zero(eltype(x))
    r, b′ = x[end], b[end]
    @inbounds for i in 2:lenx
      r = r + b′ .* x[end - i + 1]
      b′ = b′ * b[end - i + 1]
    end
    r
  end

kfold(f::KFun) = arity(f).start >= 2 ? FoldD(f) : FoldM(f)
kfold(s::Vector{Char}) = Join(s)
kfold(s::Char) = Join(Char[s])
kfold(b::Union{Int64,Vector{Int64}}) = Decode(b)

# scan

@adverb ScanM 1:2
@adverb ScanD 1:3

struct Split <: AFun
  s::Vector{Char}
end
arity(::Split)::Arity = 1:1
struct Encode{T} <: AFun
  b::T
end
arity(::Encode)::Arity = 1:1

#   F\ scan      +\1 2 3 -> 1 3 6
# TODO: is this correct?
(o::ScanD)(x) = x
(o::ScanD)(x::Vector) =
  begin
    isempty(x) ? x : begin
      ET, len = eltype(x), length(x)
      id = scanidentity(o.f, isempty(x) ? eltype(x) : typeof(x[1]))
      if id === nothing
        T = promote_type(Base.promote_op(o.f, ET, ET), ET)
        r = Vector{T}(undef, len)
        r[1] = x[1]
        accumulate!(o.f, r, x)
      else
        T = Base.promote_op(o.f, ET, ET)
        r = Vector{T}(undef, len)
        accumulate!(o.f, r, x; init=id)
      end
    end
  end
(o::ScanD)(x::AbstractDict) =
  isempty(x) ? x : OrderedDict(zip(keys(x), o(collect(values(x)))))
# x F\ seeded \  10+\1 2 3 -> 11 13 16
(o::ScanD)(x, y) = o.f(x, y)
(o::ScanD)(x, y::Vector) = isempty(y) ? y : accumulate(o.f, y, init=x)
(o::ScanD)(x, y::AbstractDict) =
  isempty(y) ? y : OrderedDict(zip(keys(y), o(x, collect(values(y)))))
# i f\ n-dos     5(2*)\1 -> 1 2 4 8 16 32
(o::ScanM)(x::Int64, y) =
  begin
    len = x + 1
    T = Base.promote_op(o.f, eltype(y))
    r = Vector{T}(undef, len)
    @inbounds r[1] = y
    i = 2
    while i <= len
      @inbounds y = r[i] = o.f(y)
      i = i + 1
    end
    r
  end
# f f\ whiles
(o::ScanM)(x::KFun, y) =
  begin
    T = promote_type(Base.promote_op(o.f, typeof(y)), typeof(y))
    r = T[y]
    while Bool(x(y))
      y = o.f(y)
      push!(r, y)
    end
    r
  end
#   f\ converges
(o::ScanM)(x) =
  begin
    T = promote_type(Base.promote_op(o.f, typeof(x)), typeof(x))
    r = T[x]
    while true
      x′ = o.f(x)
      !(hash(x′) == hash(x) && isequal(x, x′)) || break
      x = x′
      push!(r, x)
    end
    r
  end
# F\[n;x;y] n first elements of a recurrent series defined by F
(o::ScanD)(n, x, y) =
  begin
    @assert n >= 0
    T = Base.promote_op(o.f, typeof(x), typeof(x))
    r = Vector{T}(undef, n + 2)
    r[1] = x
    @inbounds while n >= 0
      n, x, y = n - 1, app(o.f, x, y), x
      r[end - n - 1] = x
    end
    r
  end
# C\ split
(o::Split)(x::Vector{Char}) = begin
  s, lens, lenx = o.s, length(o.s), length(x)
  r = Vector{Char}[]
  i, previ = 1, 1
  stopi = lenx - lens + 1
  while i <= stopi
    if s == x[i:i + lens - 1]
      push!(r, x[previ:i - 1])
      previ = i = i + lens
    else
      i = i + 1
    end
  end
  push!(r, x[previ:end])
  r
end
(o::Encode)(x::Int64) = encode1(o.b, x)
(o::Encode)(x::Vector{<:Number}) = encodeM(o.b, x)

encode1(b::Int64, x::Number) =
  begin
    T = typeof(x)
    ns, t0 = T[], zero(T)
    while x != t0
      x, n = divrem(x, b)
      push!(ns, n)
    end
    reverse!(ns)
  end
encode1(b::Vector{Int64}, x::Number) =
  begin
    T, len = typeof(x), length(b)
    ns, t0 = Vector{T}(undef, len), zero(T)
    @inbounds for i in len:-1:1
      ns[i] = if x != t0
        x, n = divrem(x, b[i])
        n
      else
        t0
      end
    end
    ns
  end
encodeM(b::Int64, x::Vector{<:Number}) =
  begin
    T, len = eltype(x), length(x)
    ns = Vector{T}[]
    len == 0 && return ns
    x, left, t0 = copy(x), len, zero(T)
    while left != 0
      row = Vector{T}(undef, len)
      @inbounds for i in 1:len
        row[i] = if x[i] != t0
          x[i], n = divrem(x[i], b)
          x[i] == t0 && (left = left - 1)
          n
        else
          t0
        end
      end
      push!(ns, row)
    end
    reverse!(ns)
  end
encodeM(b::Vector{Int64}, x::Vector{<:Number}) =
  begin
    T, lenx, lenb = eltype(x), length(x), length(b)
    lenx == 0 && return [T[] for _ in 1:lenb]
    x, ns, t0 = copy(x), Vector{Vector{T}}(undef, lenb), zero(T)
    @inbounds for j in lenb:-1:1
      row = Vector{T}(undef, lenx)
      @inbounds for i in 1:lenx
        row[i] = if x[i] != t0
          x[i], n = divrem(x[i], b[j]); n
        else
          t0
        end
      end
      ns[j] = row
    end
    ns
  end

kscan(f::KFun) = arity(f).start == 2 ? ScanD(f) : ScanM(f)
kscan(s::Vector{Char}) = Split(s)
kscan(s::Char) = Split(Char[s])
kscan(b::Union{Int64,Vector{Int64}}) = Encode(b)

# each

@adverb EachM 1:1
@adverb EachD 2:2

#   f' each1
(o::EachM)(x) = keach′(o.f, x)
# x F' each2
(o::EachD)(x, y) = o.f(x, y)
(o::EachD)(x::Vector, y) = o.f.(x, y)
(o::EachD)(x, y::Vector) = o.f.(x, y)
(o::EachD)(x::Vector, y::Vector) =
  (@assert length(x) == length(y); o.f.(x, y))

keach(f::KFun) = arity(f).start == 2 ? EachD(f) : EachM(f)

keach′(f, x) = f(x)
keach′(f, x::Vector) =
  isempty(x) ? begin
     T = Base.promote_op(f, eltype(typeof(x)))
     T[]
  end : f.(x)
keach′(f, d::AbstractDict) =
  OrderedDict(zip(keys(d), map(f, values(d))))

# verbs

# :: x
kself(x) = x

# : right
kright(x, y) = y

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
kfirst(x::Vector) = isempty(x) ? Null.null(eltype(x)) : (@inbounds x[1])
kfirst(x::AbstractDict) = isempty(x) ? Null.null(eltype(x)) : first(x).second

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

# N<N less
kless(x::Union{Int64,Float64}, y::Union{Int64,Float64}) = Int(x < y)
@dyad4char(kless)
@dyad4vector(kless)
@dyad4dict(kless)

# N>N more
kmore(x::Union{Int64,Float64}, y::Union{Int64,Float64}) = Int(x > y)
@dyad4char(kmore)
@dyad4vector(kmore)
@dyad4dict(kmore)

# <X asc
kasc(x::Vector) = sortperm(x, lt=isless) .- 1

# >X desc
kdesc(x::Vector) = sortperm(x, lt=isless, rev=true) .- 1

# ~x not
knot(x::Float64) = Int(x == 0.0)
knot(x::Int64) = Int(x == 0.0)
knot(x::Char) = Int(x == '\0')
knot(x::Symbol) = Int(x == Null.symbol_null)
knot(x::KFun) = 0
knot(x::MFun) = Int(x.f == kself)
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
    for (n, xe) in enumerate(x)
      push!(get!(allocg, g, xe), n - 1)
    end
    g
  end

# x=y eq
keq(x, y) = Int(x == y)
@dyad4char(keq)
@dyad4vector(keq)
@dyad4dict(keq)

# ,x enlist
kenlist(x) = [x]

# x,y concat
kconcat(x, y) = Any[x, y]
kconcat(x::T, y::T) where T = T[x, y]
kconcat(x, y::Vector) = Any[x, y...]
kconcat(x::T, y::Vector{T}) where T = T[x, y...]
kconcat(x::Vector, y) = Any[x..., y]
kconcat(x::Vector{T}, y::T) where T = T[x..., y]
kconcat(x::Vector, y::Vector) = Any[x..., y...]
kconcat(x::Vector{T}, y::Vector{T}) where T = vcat(x, y)
kconcat(x::AbstractDict, y::AbstractDict) = merge(x, y)

klist(x::T...) where T = [x...]
klist(x...) = Any[x...]

# ^x null
knull(x) = 0
knull(x::KAtom) = Int(Null.isnull(x))
knull(x::Vector) = knull.(x)
@monad4dict(knull)

# a^y fill
kfill(x::KAtom, y) = Null.isnull(y) ? x : y
kfill(x::KAtom, y::Vector) = kfill.(x, y)
kfill(x::KAtom, y::AbstractDict) =
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
    x == 0 && return empty(y)
    x == Null.int_null && return y
    it, len = x>0 ? (y, x) : (Iterators.reverse(y), -x)
    collect(Iterators.take(Iterators.cycle(it), len))
  end

# I#y reshape
kreshape(x::Vector{Int64}, y) = kreshape(x, [y])
kreshape(x::Vector{Int64}, y::Vector) = 
  begin
    lenx = length(x)
    lenx == 0 && return app(y, 1)
    x[1] == 0 && return Any[]
    lenx == 1 && x[1] == Null.int_null && return y
    it = Iterators.Stateful(Iterators.cycle(y))
    kreshape0(x, 1, it)
  end
kreshape0(x, idx, it) =
  begin
    @assert x[idx] >= 0
    length(x) == idx ?
      collect(Iterators.take(it, x[idx])) :
      [kreshape0(x, idx+1, it) for _ in 1:x[idx]]
  end

# f#y replicate
kreshape(x::KFun, y) = 
  replicate(y, x(y))
kreshape(x::KFun, y::AbstractDict) = 
  OrderedDict(replicate(collect(y), x(collect(values(y)))))

# x#d take
kreshape(x::Vector, y::AbstractDict) = 
  OrderedDict(zip(x, app.(Ref(y), x)))

# _n floor
kfloor(x::Int64) = x
kfloor(x::Float64) = x === NaN ? Null.int_null : floor(Int64, x)

# _c lowercase
kfloor(x::Char) = lowercase(x)
kfloor(x::Symbol) = Symbol(lowercase(string(x)))

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
kdrop(x, y::AbstractDict) =
  haskey(y, x) ?
    OrderedDict(filter(item -> 0==kmatch(item.first, x), y)) :
    y
kdrop(x::Vector, y::AbstractDict) =
  begin
    isempty(y) && return y
    xrank, yrank = rank(x), urank(first(y).first)
    if xrank >= yrank
      m = OrderedDict(x .=> true)
      OrderedDict(filter(item -> !haskey(m, item.first), y))
    else
      haskey(y, x) ?
        OrderedDict(filter(item -> 0==kmatch(item.first, x), y)) :
        y
    end
  end

# I_Y cut
kdrop(x::Vector{Int64}, y::Vector) =
  begin
    o = Vector{eltype(y)}[]
    len = length(y)
    previ = -1
    for i in x
      @assert i < len + 1 "domain error"
      if previ != -1
        @assert i >= previ
        push!(o, y[previ + 1:i])
      end
      previ = i
    end
    push!(o, y[previ + 1:end])
    o
  end

# f_Y filter out
kdrop(x::KFun, y::Vector) = y[0 .=== x(y)]

# X_i delete
kdrop(x::Vector, y::Int64) =
  y < 0 || y >= length(x) ? x : deleteat!(copy(x), [y+1])
kdrop(x::AbstractDict, y) =
  delete!(copy(x), y)

# $x string
kstring(x::KAtom) = collect(string(x))
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

# ?i rand
kuniq(x::Int64) = rand(x)

# ?X uniq
kuniq(x::Vector) =
  begin
    T = eltype(x)
    o, m = T[], OrderedDict{T,Bool}()
    @inbounds for i in 1:length(x)
      e = x[i]
      idx = ht_keyindex2(m, e)
      if idx < 0
        push!(o, e)
        _setindex!(m, true, e, -idx)
      end
    end
    o
  end

# .d values
kget(x::AbstractDict) = collect(values(x))

# x.y appn
kappn(x, y) = app(x, y)
kappn(x, y::Vector) = app(x, y...)
kappn(x, y::AbstractDict) = @assert false "type"

# @x type
ktype(x::Int64) = :i
ktype(x::Float64) = :d
ktype(x::Symbol) = :s
ktype(x::Char) = :c
ktype(x::Vector{Int64}) = :I
ktype(x::Vector{Float64}) = :D
ktype(x::Vector{Symbol}) = :S
ktype(x::Vector{Char}) = :C
ktype(x::Vector) = :A
ktype(x::Train) = :q

# X?y find
kfind(x::Vector, y) = kfind1(x, y)
kfind(x::Vector, y::Vector) = kfindM(x, y, rank(x), rank(y))

kfind1(x::Vector, y) =
  begin
    i = findfirst(y′ -> 1==kmatch(y, y′), x)
    i !== nothing ? i - 1 : Null.int_null
  end
kfindM(x::Vector, y::Vector) =
  begin
    isempty(y) && return Int64[]
    m = Dict(x′ => i - 1 for (i, x′) in enumerate(x))
    map(y′ -> get(m, y′, Null.int_null), y)
  end
kfindM(x::Vector, y, xrank::Int64, yrank::Int64) =
  kfind1(x, y)
kfindM(x::Vector, y::Vector, xrank::Int64, yrank::Int64) =
  begin
    yrank == xrank ?
    kfindM(x, y) :
    yrank >= xrank ?
    kfindM.(Ref(x), y, xrank, yrank - 1) :
    kfind1(x, y)
  end

end

module Compile
using ..Syntax,..Parse
import ..Runtime as R

verbs = Dict(
             Symbol(raw"::") => R.MFun(R.kself),
             Symbol(raw":")  => R.DFun(R.kright),
             Symbol(raw"+:") => R.MFun(R.kflip),
             Symbol(raw"+")  => R.DFun(R.kadd),
             Symbol(raw"-:") => R.MFun(R.kneg),
             Symbol(raw"-")  => R.DFun(R.ksub),
             Symbol(raw"*:") => R.MFun(R.kfirst),
             Symbol(raw"*")  => R.DFun(R.kmul),
             Symbol(raw"%:") => R.MFun(R.ksqrt),
             Symbol(raw"%")  => R.DFun(R.kdiv),
             Symbol(raw"!:") => R.MFun(R.kenum),
             Symbol(raw"!")  => R.DFun(R.kmod),
             Symbol(raw"&:") => R.MFun(R.kwhere),
             Symbol(raw"&")  => R.DFun(R.kand),
             Symbol(raw"|:") => R.MFun(R.krev),
             Symbol(raw"|")  => R.DFun(R.kor),
             Symbol(raw"<:") => R.MFun(R.kasc),
             Symbol(raw"<")  => R.DFun(R.kless),
             Symbol(raw">:") => R.MFun(R.kdesc),
             Symbol(raw">")  => R.DFun(R.kmore),
             Symbol(raw"~:") => R.MFun(R.knot),
             Symbol(raw"~")  => R.DFun(R.kmatch),
             Symbol(raw"=:") => R.MFun(R.kgroup),
             Symbol(raw"=")  => R.DFun(R.keq),
             Symbol(raw",:") => R.MFun(R.kenlist),
             Symbol(raw",")  => R.DFun(R.kconcat),
             Symbol(raw"^:") => R.MFun(R.knull),
             Symbol(raw"^")  => R.DFun(R.kfill),
             Symbol(raw"#:") => R.MFun(R.klen),
             Symbol(raw"#")  => R.DFun(R.kreshape),
             Symbol(raw"_:") => R.MFun(R.kfloor),
             Symbol(raw"_")  => R.DFun(R.kdrop),
             Symbol(raw"$:") => R.MFun(R.kstring),
             Symbol(raw"?:") => R.MFun(R.kuniq),
             Symbol(raw".:") => R.MFun(R.kget),
             Symbol(raw".")  => R.DFun(R.kappn),
             Symbol(raw"@")  => R.AppFun(),
             Symbol(raw"@:") => R.MFun(R.ktype),
             Symbol(raw"?")  => R.DFun(R.kfind),
            )

vself = verbs[:(::)]

adverbs = Dict(
               Symbol(raw"/")  => R.kfold,
               Symbol(raw"\\") => R.kscan,
               Symbol(raw"'")  => R.keach,
              )

compile(str::String) = compile(Parse.parse(str))
compile(syn::Seq) = quote $(map(compile1, syn.body)...) end

compile1(syn::App) =
  begin
    f, args = syn.head, syn.args
    args, pargs =
      begin
        args′, pargs = [], []
        for arg in args
          if arg isa Omit
            parg = gensym()
            push!(pargs, parg)
            push!(args′, parg)
          else
            push!(args′, compile1(arg))
          end
        end
        args′, pargs
      end
    if isempty(args); args = [vself] end
    if f isa Verb && f.v === :(:) &&
        length(args)==2 && args[1] isa Symbol
      # assignment `n:x`
      @assert isempty(pargs) "cannot project n:x"
      name,rhs=args
      :(begin $name = $rhs end)
    elseif f isa Verb && f.v === :($) && length(args)==3
      # conditional `$[c;t;e]`
      @assert isempty(pargs) raw"cannot project $[c;t;e]"
      c,t,e=args
      :(if $c==1; $t; else $e end)
    elseif f isa Verb && f.v===:(:) && length(args)==1
      # return `:x`
      @assert isempty(pargs) "cannot project :x"
      rhs=args[1]
      :(return $rhs)
    elseif f isa Union{Verb,Adverb}
      # @assert length(args) in (1, 2)
      f = compilefun(f)
      compileapp(f, args, pargs)
    elseif f isa Fun
      f = compile1(f)
      compileapp(f, args, pargs)
    else # generic case
      f = compile1(f)
      compileapp(f, args, pargs)
    end
  end
compile1(syn::Fun) =
  begin
    x,y,z=implicitargs(syn.body)
    body = !isempty(syn.body) ?
      map(compile1, syn.body) :
      [:($vself)]
    if z
      :($(R.Fun)((x, y, z) -> $(body...), 3))
    elseif y
      :($(R.DFun)((x, y) -> $(body...)))
    elseif x
      :($(R.MFun)((x) -> $(body...)))
    else
      :($(R.MFun)((x) -> $(body...)))
    end
  end
compile1(syn::Lit) =
  if syn.v isa String
    v = length(syn.v) == 1 ? syn.v[1] : collect(syn.v)
    :($v)
  elseif syn.v isa Symbol
    Meta.quot(syn.v)
  else
    syn.v
  end
compile1(syn::Id) = :($(syn.v))
compile1(syn::Seq) =
  compileargs(syn.body) do args
    :($(R.klist)($(args...)))
  end
compile1(syn::LSeq) =
  begin
    T = length(syn.body) == 1 ?
      typeof(syn.body[1].v) :
      foldl(promote_type, map(e -> typeof(e.v), syn.body))
    :($T[$(map(compile1, syn.body)...)])
  end
compile1(syn::LBind) = compile1(App(syn.v, syn.arg))
compile1(syn::Union{Verb,Adverb,Train}) = :($(compilefun(syn)))

compileargs(f, args::Vector) =
  begin
    bindings = []
    args′ = []
    for arg in args
      arg = arg isa Syn ? compile1(arg) : arg
      sym = gensym("arg")
      push!(bindings, :($sym = $arg;))
      push!(args′, sym)
    end
    :(begin; $(bindings...); $(f(args′)) end)
  end

compileapp(f, args, pargs) =
  isempty(pargs) ? compileapp(f, args) :
  begin
    f′ = gensym("f")
    expr = compileapp(f′, args)
    :(let $f′ = $f
        if $f′ isa $(R.KFun)
          $(R.Fun)(($(pargs...),) -> $expr, $(length(pargs)))
        else
          let $(map(arg -> :($arg = :), pargs)...);
            $expr
          end
        end
      end)
  end
compileapp(f::R.KFun, args, pargs) =
  isempty(pargs) ?
    compileapp(f, args) :
    :($(R.Fun)(($(pargs...),) ->
      $(compileapp(f, args)), $(length(pargs))))
compileapp(f, args) =
  compileargs(args) do args
    :($(R.app)($(f), $(args...)))
  end
compileapp(f::R.KFun, args) =
  begin
    flen, alen = R.arity(f), length(args)
    if alen < flen.start && !any(a -> a isa Union{Expr,Symbol}, args)
      R.app(f, args...)
    else
      compileargs(args) do args
        alen in flen ? :($f($(args...))) :
        alen < flen.start ? :($(R.app)($f, $(args...))) :
        @assert false "invalid arity"
      end
    end
  end

compilefun(syn) = compile1(syn)
compilefun(syn::Train) =
  :($(R.Train)($(compile1(syn.head)), $(compile1(syn.next))))
compilefun(syn::Verb) =
  begin
    f = get(verbs, syn.v, nothing)
    @assert f !== nothing "primitive is not implemented: $(syn.v)"
    f
  end
compilefun(syn::Adverb) =
  begin
    adverb = get(adverbs, syn.v, nothing)
    @assert adverb !== nothing "adverb is not implemented: $(syn.v)"
    verb = compilefun(syn.arg)
    if verb isa R.KFun
      adverb(verb)
    else
      :($adverb($verb))
    end
  end

implicitargs(syn::Id) = syn.v===:x,syn.v===:y,syn.v===:z
implicitargs(syn::Union{Omit,Lit,Verb,Fun,LSeq}) = false,false,false
implicitargs(syn::Union{Adverb}) = implicitargs([syn.arg])
implicitargs(syn::App) = implicitargs([syn.head, syn.args...])
implicitargs(syn::Fun) = false,false,false
implicitargs(syn::LBind) = implicitargs(syn.arg)
implicitargs(syn::Train) = implicitargs([syn.head, syn.next])
implicitargs(syn::Seq) = implicitargs(syn.body)
implicitargs(syns::Vector) =
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

macro k_str(k)
  code = compile(parse(k))
  :($(esc(code)))
end

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
  initrepl(compile,
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

export k, @k_str

end # module
