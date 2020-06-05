"""
    parse_kw(ps::ParseState)

Dispatch function for when the parser has reached a keyword.
"""
function parse_kw(ps::ParseState)
    k = kindof(ps.t)
    if k === Tokens.IF
        return @default ps @closer ps :block parse_if(ps)
    elseif k === Tokens.LET
        return @default ps @closer ps :block parse_blockexpr(ps, :Let)
    elseif k === Tokens.TRY
        return @default ps @closer ps :block parse_try(ps)
    elseif k === Tokens.FUNCTION
        return @default ps @closer ps :block parse_blockexpr(ps, :Function)
    elseif k === Tokens.MACRO
        return @default ps @closer ps :block parse_blockexpr(ps, :Macro)
    elseif k === Tokens.BEGIN
        @static if VERSION < v"1.4"
            return @default ps @closer ps :block parse_blockexpr(ps, :Begin)
        else
            if ps.closer.inref
                ret = EXPR(ps)
            else
                return @default ps @closer ps :block parse_blockexpr(ps, :Begin)
            end
        end
    elseif k === Tokens.QUOTE
        return @default ps @closer ps :block parse_blockexpr(ps, :Quote)
    elseif k === Tokens.FOR
        return @default ps @closer ps :block parse_blockexpr(ps, :For)
    elseif k === Tokens.WHILE
        return @default ps @closer ps :block parse_blockexpr(ps, :While)
    elseif k === Tokens.BREAK
        return EXPR(ps)
    elseif k === Tokens.CONTINUE
        return EXPR(ps)
    elseif k === Tokens.IMPORT
        return parse_imports(ps)
    elseif k === Tokens.USING
        return parse_imports(ps)
    elseif k === Tokens.EXPORT
        return parse_export(ps)
    elseif k === Tokens.MODULE
        return @default ps @closer ps :block parse_blockexpr(ps, :Module)
    elseif k === Tokens.BAREMODULE
        return @default ps @closer ps :block parse_blockexpr(ps, :BareModule)
    elseif k === Tokens.CONST
        return @default ps parse_const(ps)
    elseif k === Tokens.GLOBAL
        return @default ps parse_global(ps)
    elseif k === Tokens.LOCAL
        return @default ps parse_local(ps)
    elseif k === Tokens.RETURN
        return @default ps parse_return(ps)
    elseif k === Tokens.END
        if ps.closer.square
            ret = EXPR(ps)
        else
            ret = mErrorToken(ps, EXPR(:Identifier, ps), UnexpectedToken)
        end
        return ret
    elseif k === Tokens.ELSE || k === Tokens.ELSEIF || k === Tokens.CATCH || k === Tokens.FINALLY
        return mErrorToken(ps, EXPR(:Identifier, ps), UnexpectedToken)
    elseif k === Tokens.ABSTRACT
        return @default ps parse_abstract(ps)
    elseif k === Tokens.PRIMITIVE
        return @default ps parse_primitive(ps)
    elseif k === Tokens.TYPE
        return EXPR(:Identifier, ps)
    elseif k === Tokens.STRUCT
        return @default ps @closer ps :block parse_blockexpr(ps, :Struct)
    elseif k === Tokens.MUTABLE
        return @default ps @closer ps :block parse_mutable(ps)
    elseif k === Tokens.OUTER
        return EXPR(:Identifier, ps)
    else
        return mErrorToken(ps, Unknown)
    end
end

function parse_const(ps::ParseState)
    kw = EXPR(ps)
    arg = parse_expression(ps)
    if !(is_assignment(unwrapbracket(arg)) || (headof(arg) === :Global && is_assignment(unwrapbracket(arg.args[1]))))
        arg = mErrorToken(ps, arg, ExpectedAssignment)
    end
    ret = EXPR(:Const, EXPR[arg], EXPR[kw])
    return ret
end

function parse_global(ps::ParseState)
    kw = EXPR(ps)
    arg = parse_expression(ps)

    return EXPR(:Global, EXPR[arg], EXPR[kw])
end

function parse_local(ps::ParseState)
    kw = EXPR(ps)
    arg = parse_expression(ps)

    return EXPR(:Local, EXPR[arg], EXPR[kw])
end

function parse_return(ps::ParseState)
    kw = EXPR(ps)
    # Note to self: Nothing could be treated as implicit and added
    # during conversion to Expr.
    arg = closer(ps) ? EXPR(:nothing, 0, 0, "") : parse_expression(ps)

    return EXPR(:Return, EXPR[arg], EXPR[kw])
end

function parse_abstract(ps::ParseState)
    if kindof(ps.nt) === Tokens.TYPE
        kw1 = EXPR(ps)
        kw2 = EXPR(next(ps))
        sig = @closer ps :block parse_expression(ps)
        ret = EXPR(:Abstract, EXPR[sig], EXPR[kw1, kw2, accept_end(ps)])
    else
        ret = EXPR(:Identifier, ps)
    end
    return ret
end

function parse_primitive(ps::ParseState)
    if kindof(ps.nt) === Tokens.TYPE
        kw1 = EXPR(ps)
        kw2 = EXPR(next(ps))
        sig = @closer ps :ws @closer ps :wsop parse_expression(ps)
        arg = @closer ps :block parse_expression(ps)
        ret = EXPR(:Primitive, EXPR[sig, arg], EXPR[kw1, kw2, accept_end(ps)])
    else
        ret = EXPR(:Identifier, ps)
    end
    return ret
end

function parse_mutable(ps::ParseState)
    if kindof(ps.nt) === Tokens.STRUCT
        kw = EXPR(ps)
        next(ps)
        ret = parse_blockexpr(ps, :Mutable)
        pushfirst!(ret.trivia, setparent!(kw, ret))
        update_span!(ret)
    else
        ret = EXPR(:Identifier, ps)
    end
    return ret
end

function parse_imports(ps::ParseState)
    kw = EXPR(ps)
    kwt = is_import(kw) ? :Import : :Using

    arg = parse_dot_mod(ps)
    if !iscomma(ps.nt) && !iscolon(ps.nt)
        ret = EXPR(kwt, EXPR[arg], EXPR[kw])
    elseif iscolon(ps.nt)
        ret = EXPR(kwt, EXPR[EXPR(EXPR(:Operator, next(ps)), EXPR[arg])], EXPR[kw])
        
        arg = parse_dot_mod(ps, true)
        push!(ret.args[1], arg)
        while iscomma(ps.nt)
            pushtotrivia!(ret.args[1], accept_comma(ps))
            arg = parse_dot_mod(ps, true)
            push!(ret.args[1], arg)
        end
        update_span!(ret)
    else
        ret = EXPR(kwt, EXPR[arg], EXPR[kw])
        while iscomma(ps.nt)
            pushtotrivia!(ret, accept_comma(ps))
            arg = parse_dot_mod(ps)
            push!(ret, arg)
        end
    end

    return ret
end

function parse_export(ps::ParseState)
    args = EXPR[]
    trivia = EXPR[EXPR(ps)]
    push!(args, parse_importexport_item(ps))

    while iscomma(ps.nt)
        push!(trivia, EXPR(next(ps)))
        arg = parse_importexport_item(ps)
        push!(args, arg)
    end

    return EXPR(:Export, args, trivia)
end

"""
    parse_blockexpr_sig(ps::ParseState, head)

Utility function to parse the signature of a block statement (i.e. any statement preceding
the main body of the block). Returns `nothing` in some cases (e.g. `begin end`)
"""
function parse_blockexpr_sig(ps::ParseState, head)
    if head === :Struct || head == :Mutable || head === :While
        return @closer ps :ws parse_expression(ps)
    elseif head === :For
        return parse_iterators(ps)
    elseif head === :Function || head === :Macro
        sig = @closer ps :inwhere @closer ps :ws parse_expression(ps)
        if convertsigtotuple(sig)
            sig = EXPR(:Tuple, sig.args)
        end
        while kindof(ps.nt) === Tokens.WHERE && kindof(ps.ws) != Tokens.NEWLINE_WS
            sig = @closer ps :inwhere @closer ps :ws parse_operator_where(ps, sig, INSTANCE(next(ps)), false)
        end
        return sig
    elseif head === :Let
        if isendoflinews(ps.ws)
            return EXPR(:Block, EXPR[], nothing)
        else
            arg = @closer ps :comma @closer ps :ws  parse_expression(ps)
            if iscomma(ps.nt) || !(is_wrapped_assignment(arg) || isidentifier(arg))
                arg = EXPR(:Block, EXPR[arg])
                while iscomma(ps.nt)
                    pushtotrivia!(arg, accept_comma(ps))
                    startbyte = ps.nt.startbyte
                    nextarg = @closer ps :comma @closer ps :ws parse_expression(ps)
                    push!(arg, nextarg)
                end
            end
            return arg
        end
    elseif head === :Do
        args, trivia = EXPR[], EXPR[]
        @closer ps :comma @closer ps :block while !closer(ps)
            push!(args, @closer ps :ws a = parse_expression(ps))
            if kindof(ps.nt) === Tokens.COMMA
                push!(trivia, accept_comma(ps))
            elseif @closer ps :ws closer(ps)
                break
            end
        end
        return EXPR(:Tuple, args, trivia)
    elseif head === :Module || head === :BareModule
        return isidentifier(ps.nt) ? EXPR(:Identifier, next(ps)) :
            @precedence ps 15 @closer ps :ws parse_expression(ps)
    end
    return nothing
end

function parse_do(ps::ParseState, pre::EXPR)
    args, trivia = EXPR[pre], EXPR[EXPR(next(ps))]
    args1, trivia1 = EXPR[], EXPR[]
    @closer ps :comma @closer ps :block while !closer(ps)
        push!(args1, @closer ps :ws a = parse_expression(ps))
        if kindof(ps.nt) === Tokens.COMMA
            push!(trivia1, accept_comma(ps))
        elseif @closer ps :ws closer(ps)
            break
        end
    end
    blockargs = parse_block(ps, EXPR[], (Tokens.END,))
    push!(args, (EXPR(EXPR(:Operator, 0, 0, "->"), EXPR[EXPR(:Tuple, args1, trivia1), EXPR(:Block, blockargs, nothing)])))
    push!(trivia, accept_end(ps))
    return EXPR(:Do, args, trivia)
end

"""
    parse_blockexpr(ps::ParseState, head)

General function for parsing block expressions comprised of a series of statements 
terminated by an `end`.
"""
function parse_blockexpr(ps::ParseState, head)
    kw = EXPR(ps)
    sig = parse_blockexpr_sig(ps, head)
    blockargs = parse_block(ps, EXPR[], (Tokens.END,), docable(head))
    if head === :Begin
        EXPR(:Block, blockargs, EXPR[kw, accept_end(ps)])
    elseif sig === nothing
        EXPR(head, EXPR[EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    elseif (head === :Function || head === :Macro) && is_either_id_op_interp(sig)
        EXPR(head, EXPR[sig], EXPR[kw, accept_end(ps)])
    elseif head === :Mutable
        EXPR(:Struct, EXPR[EXPR(:(var"true"), 0, 0), sig, EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    elseif head === :Module
        EXPR(head, EXPR[EXPR(:(var"true"), 0, 0), sig, EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    elseif head === :BareModule
        EXPR(:Module, EXPR[EXPR(:(var"false"), 0, 0), sig, EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    elseif head === :Struct
        EXPR(head, EXPR[EXPR(:(var"false"), 0, 0), sig, EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    else
        EXPR(head, EXPR[sig, EXPR(:Block, blockargs, nothing)], EXPR[kw, accept_end(ps)])
    end
end


"""
    parse_if(ps, nested=false)

Parse an `if` block.
"""
function parse_if(ps::ParseState, nested = false)
    args = EXPR[]
    trivia = EXPR[EXPR(ps)]

    push!(args, isendoflinews(ps.ws) ? mErrorToken(ps, MissingConditional) : @closer ps :ws parse_expression(ps))
    push!(args, EXPR(:Block, parse_block(ps, EXPR[], (Tokens.END, Tokens.ELSE, Tokens.ELSEIF)), nothing))

    elseblockargs = EXPR[]
    if kindof(ps.nt) === Tokens.ELSEIF
        push!(args, parse_if(next(ps), true))
    end
    elsekw = kindof(ps.nt) === Tokens.ELSE
    if kindof(ps.nt) === Tokens.ELSE
        push!(trivia, EXPR(next(ps)))
        parse_block(ps, elseblockargs)
    end

    # Construction
    if !(isempty(elseblockargs) && !elsekw)
        push!(args, EXPR(:Block, elseblockargs, nothing))
    end
    !nested && push!(trivia, accept_end(ps))

    return EXPR(nested ? :ElseIf : :If, args, trivia)
end


function parse_try(ps::ParseState)
    kw = EXPR(ps)
    args = EXPR[]
    trivia = EXPR[kw]
    tryblockargs = parse_block(ps, EXPR[], (Tokens.END, Tokens.CATCH, Tokens.FINALLY))
    push!(args, EXPR(:Block, tryblockargs, nothing))

    #  catch block
    if kindof(ps.nt) === Tokens.CATCH
        push!(trivia, EXPR(next(ps)))
        # catch closing early
        if kindof(ps.nt) === Tokens.FINALLY || kindof(ps.nt) === Tokens.END
            caught = EXPR(:(var"false"), 0, 0, "")
            catchblock = EXPR(:Block, EXPR[])
        else
            if isendoflinews(ps.ws)
                caught = EXPR(:(var"false"), 0, 0, "")
            else
                caught = @closer ps :ws parse_expression(ps)
            end

            catchblockargs = parse_block(ps, EXPR[], (Tokens.END, Tokens.FINALLY))
            if !(is_either_id_op_interp(caught) || headof(caught) === :(var"false"))
                pushfirst!(catchblockargs, caught)
                caught = EXPR(:(var"false"), 0, 0, "")
            end
            catchblock = EXPR(:Block, catchblockargs, nothing)
        end
    else
        caught = EXPR(:(var"false"), 0, 0, "")
        catchblock = EXPR(:Block, EXPR[], nothing)
    end
    push!(args, caught)
    push!(args, catchblock)

    # finally block
    if kindof(ps.nt) === Tokens.FINALLY
        if isempty(catchblock.args)
            args[3] = EXPR(:(var"false"), 0, 0, "")
        end
        push!(trivia, EXPR(next(ps)))
        finallyblockargs = parse_block(ps)
        push!(args, EXPR(:Block, finallyblockargs))
    end

    push!(trivia, accept_end(ps))
    return EXPR(:Try, args, trivia)
end
