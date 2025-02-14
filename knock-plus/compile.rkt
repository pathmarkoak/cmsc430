#lang racket
(provide (all-defined-out))
(require "ast.rkt")
(require "compile-ops.rkt")
(require "types.rkt")
(require a86/ast)

(define rax 'rax)
(define rbx 'rbx) ; heap
(define rsp 'rsp) ; stack
(define rdi 'rdi) ; arg
(define r8  'r8)  ; scratch
(define rcx 'rcx) ; scratch
(define r15 'r15) ; stack pad (non-volatile)

;; Prog -> Asm
(define (compile p)
  (match p
    [(Prog ds e)
     (prog (Global 'entry)
           (Extern 'peek_byte)
           (Extern 'read_byte)
           (Extern 'write_byte)
           (Extern 'raise_error)
           (Label 'entry)
           (Push rbx)    ; save callee-saved register
           (Push r15)
           (Mov rbx rdi) ; recv heap pointer

           (compile-e e '() #f)
           (Pop r15)     ; restore callee-save register
           (Pop rbx)
           (Ret)
           (compile-defines ds)
           (Label 'err)
           pad-stack
           (Call 'raise_error))]))

;; [Listof Defn] -> Asm
(define (compile-defines ds)
  (match ds
    ['() (seq)]
    [(cons d ds)
     (seq (compile-define d)
          (compile-defines ds))]))

;; Defn -> Asm
(define (compile-define d)
  (match d
    [(Defn f xs e)
     (seq (Label (symbol->label f))
          (compile-e e (reverse xs) #t)
          (Add rsp (* 8 (length xs))) ; pop args
          (Ret))]))

;; type CEnv = (Listof [Maybe Id])
;; Expr CEnv Boolean -> Asm
(define (compile-e e c t?)
  (match e
    [(Lit d) (compile-value d)]
    [(Eof) (compile-value eof)]
    [(Var x) (compile-variable x c)]
    [(Prim0 p) (compile-prim0 p)]
    [(Prim1 p e) (compile-prim1 p e c)]
    [(Prim2 p e1 e2) (compile-prim2 p e1 e2 c)]
    [(Prim3 p e1 e2 e3) (compile-prim3 p e1 e2 e3 c)]
    [(PrimN p es) (compile-primN p es c)]
    [(If e1 e2 e3)
     (compile-if e1 e2 e3 c t?)]
    [(Begin e1 e2)
     (compile-begin e1 e2 c t?)]
    [(Let x e1 e2)
     (compile-let x e1 e2 c t?)]
    [(App f es)
     (compile-app f es c t?)]
    [(Match e ps es) (compile-match e ps es c t?)]))

;; Value -> Asm
(define (compile-value v)
  (cond [(string? v) (compile-string v)]
        [else        (Mov rax (value->bits v))]))

;; Id CEnv -> Asm
(define (compile-variable x c)
  (let ((i (lookup x c)))
    (seq (Mov rax (Offset rsp i)))))

;; String -> Asm
(define (compile-string s)
  (let ((len (string-length s)))
    (if (zero? len)
        (seq (Mov rax type-str))
        (seq (Mov rax len)
             (Mov (Offset rbx 0) rax)
             (compile-string-chars (string->list s) 8)
             (Mov rax rbx)
             (Or rax type-str)
             (Add rbx
                  (+ 8 (* 4 (if (odd? len) (add1 len) len))))))))

;; [Listof Char] Integer -> Asm
(define (compile-string-chars cs i)
  (match cs
    ['() (seq)]
    [(cons c cs)
     (seq (Mov rax (char->integer c))
          (Mov (Offset rbx i) 'eax)
          (compile-string-chars cs (+ 4 i)))]))

;; Op0 -> Asm
(define (compile-prim0 p)
  (compile-op0 p))

(define (compile-prim1 p e c)
  (seq (compile-e e c #f)
       (compile-op1 p)))

;; Op2 Expr Expr CEnv -> Asm
(define (compile-prim2 p e1 e2 c)
  (seq (compile-e e1 c #f)
       (Push rax)
       (compile-e e2 (cons #f c) #f)
       (compile-op2 p)))

;; Op3 Expr Expr Expr CEnv -> Asm
(define (compile-prim3 p e1 e2 e3 c)
  (seq (compile-e e1 c #f)
       (Push rax)
       (compile-e e2 (cons #f c) #f)
       (Push rax)
       (compile-e e3 (cons #f (cons #f c)) #f)
       (compile-op3 p)))

;; OpN [Listof Expr] CEnv -> Asm
(define (compile-primN p es c)
  (seq (compile-es es c)
       (compile-opN p (length es))))

;; Expr Expr Expr CEnv Boolean -> Asm
(define (compile-if e1 e2 e3 c t?)
  (let ((l1 (gensym 'if))
        (l2 (gensym 'if)))
    (seq (compile-e e1 c #f)
         (Cmp rax (value->bits #f))
         (Je l1)
         (compile-e e2 c t?)
         (Jmp l2)
         (Label l1)
         (compile-e e3 c t?)
         (Label l2))))
;; Expr Expr CEnv Boolean -> Asm
(define (compile-begin e1 e2 c t?)
  (seq (compile-e e1 c #f)
       (compile-e e2 c t?)))
;; Id Expr Expr CEnv Boolean -> Asm
(define (compile-let x e1 e2 c t?)
  (seq (compile-e e1 c #f)
       (Push rax)
       (compile-e e2 (cons x c) t?)
       (Add rsp 8)))

;; Id [Listof Expr] CEnv -> Asm
;; The return address is placed above the arguments, so callee pops
;; arguments and return address is next frame

;; Id [Listof Expr] CEnv Boolean -> Asm
(define (compile-app f es c t?)
  (if t?
      (compile-app-tail f es c)
      (compile-app-nontail f es c)))

;; Id [Listof Expr] CEnv -> Asm
(define (compile-app-tail f es c)
  (seq (compile-es es c)
       (move-args (length es) (length c))
       (Add rsp (* 8 (length c)))
       (Jmp (symbol->label f))))

;; Integer Integer -> Asm
(define (move-args i off)
  (cond [(zero? off) (seq)]
        [(zero? i)   (seq)]
        [else
         (seq (Mov r8 (Offset rsp (* 8 (sub1 i))))
              (Mov (Offset rsp (* 8 (+ off (sub1 i)))) r8)
              (move-args (sub1 i) off))]))
;; Id [Listof Expr] CEnv -> Asm
(define (compile-app-nontail f es c)
  (let ((r (gensym 'ret)))
    (seq (Lea rax r)
         (Push rax)
         (compile-es es (cons #f c))
         (Jmp (symbol->label f))
         (Label r))))

;; [Listof Expr] CEnv -> Asm
(define (compile-es es c)
  (match es
    ['() '()]
    [(cons e es)
     (seq (compile-e e c #f)
          (Push rax)
          (compile-es es (cons #f c)))]))

;; Expr [Listof Pat] [Listof Expr] CEnv Bool -> Asm
(define (compile-match e ps es c t?)
  (let ((done (gensym)))
    (seq (compile-e e c #f)
         (Push rax) ; save away to be restored by each clause
         (compile-match-clauses ps es (cons #f c) done t?)
         (Jmp 'err)
         (Label done)
         (Add rsp 8)))) ; pop the saved value being matched

;; [Listof Pat] [Listof Expr] CEnv Symbol Bool -> Asm
(define (compile-match-clauses ps es c done t?)
  (match* (ps es)
    [('() '()) (seq)]
    [((cons p ps) (cons e es))
     (seq (compile-match-clause p e c done t?)
          (compile-match-clauses ps es c done t?))]))

;; Pat Expr CEnv Symbol Bool -> Asm
(define (compile-match-clause p e c done t?)
  (let ((next (gensym)))
    (match (compile-pattern p '() next)
      [(list i cm)
       (seq (Mov rax (Offset rsp 0)) ; restore value being matched
            i
            (compile-e e (append cm c) t?)
            (Add rsp (* 8 (length cm)))
            (Jmp done)
            (Label next))])))

;; Pat CEnv Symbol -> (list Asm CEnv)
(define (compile-pattern p cm next)
  (match p
    [(Var '_)
     (list (seq) cm)]
    [(Var x)
     (list (seq (Push rax)) (cons x cm))]
    [(Lit l)
     (let ((ok (gensym)))
       (list (seq (Cmp rax (value->bits l))
                  (Je ok)
                  (Add rsp (* 8 (length cm)))
                  (Jmp next)
                  (Label ok))
             cm))]
    [(Conj p1 p2)
     (match (compile-pattern p1 (cons #f cm) next)
       [(list i1 cm1)
        (match (compile-pattern p2 cm1 next)
          [(list i2 cm2)
           (list
            (seq (Push rax)
                 i1
                 (Mov rax (Offset rsp (* 8 (- (sub1 (length cm1)) (length cm)))))
                 i2)
            cm2)])])]
    [(Box p)
     (match (compile-pattern p cm next)
       [(list i1 cm1)
        (let ((ok (gensym)))
          (list
           (seq (Mov r8 rax)
                (And r8 ptr-mask)
                (Cmp r8 type-box)
                (Je ok)
                (Add rsp (* 8 (length cm))) ; haven't pushed anything yet
                (Jmp next)
                (Label ok)
                (Xor rax type-box)
                (Mov rax (Offset rax 0))
                i1)
           cm1))])]
    [(Cons p1 p2)
     (match (compile-pattern p1 (cons #f cm) next)
       [(list i1 cm1)
        (match (compile-pattern p2 cm1 next)
          [(list i2 cm2)
           (let ((ok (gensym)))
             (list
              (seq (Mov r8 rax)
                   (And r8 ptr-mask)
                   (Cmp r8 type-cons)
                   (Je ok)
                   (Add rsp (* 8 (length cm))) ; haven't pushed anything yet
                   (Jmp next)
                   (Label ok)
                   (Xor rax type-cons)
                   (Mov r8 (Offset rax 0))
                   (Push r8)                ; push cdr
                   (Mov rax (Offset rax 8)) ; mov rax car
                   i1
                   (Mov rax (Offset rsp (* 8 (- (sub1 (length cm1)) (length cm)))))
                   i2)
              cm2))])])]
    ;; Done
    [(List ps)
     (match ps
      ['()
        (let ((ok (gensym)))
          (list (seq (Cmp rax (value->bits '()))
                     (Je ok)
                     (Add rsp (* 8 (length cm)))
                     (Jmp next)
                     (Label ok)) 
                cm))]
      [(cons p px)
       (match (compile-pattern p (cons #f cm) next)
          [(list i1 cm1)
            (match (compile-pattern (List px) cm1 next)
              [(list i2 cm2)
               (let ((ok (gensym))
                    (not (gensym)))
                (list (seq (Mov r8 rax)
                           (And r8 ptr-mask)
                           (Cmp r8 type-cons)
                           (Jne not)

                           (Cmp rax (value->bits '()))
                           (Jne ok)

                           (Label not)
                           (Add rsp (* 8 (length cm))) ;; haven't pushed anything to stack yet
                           (Jmp next)

                           (Label ok)
                           (Xor rax type-cons)
                           (Mov r8 (Offset rax 0))
                           (Push r8) ; push "cdr"
                           (Mov rax (Offset rax 8))
                           i1
                           (Mov rax (Offset rsp (* 8 (- (sub1 (length cm1)) (length cm)))))
                           i2)
                  cm2))])])])]
    ;; Done?
    [(Vect ps)
      (match ps
        ['()
          (let ((ok1 (gensym)))
            (list (seq (Cmp rax type-vect)
                       (Je ok1)
                       (Add rsp (* 8 (length cm)))
                       (Jmp next)
                       (Label ok1)) 
                cm))]
        [(cons p px)
          (match (compile-vec-helper (Vect ps) cm next 8)
            [(list i1 cm1)
                (let ((ok (gensym))
                      (not (gensym)))
                  (list (seq (Mov r8 rax)
                             (And r8 ptr-mask)
                             (Cmp r8 type-vect)
                             (Jne not)

                             (Cmp rax type-vect)
                             (Je not)

                             (Xor rax type-vect)
                             (Mov r8 (Offset rax 0))
                             (Cmp r8 (length ps)) ;; ensuring length is equal
                             (Je ok)

                             (Label not)
                             (Add rsp (* 8 (length cm)))

                             (Jmp next)
                             (Label ok)
                            i1)
                    cm1))])])]

    ;; Done
    [(Pred f)
      (let ((r (gensym 'ret))
           (ok (gensym)))
        (list (seq (Lea r8 r)
                   (Push r8)
                   (Push rax)
                   (Jmp (symbol->label f))
                   (Label r)
                   (Cmp rax (value->bits #f))
                   (Jne ok)
                   (Add rsp (* 8 (length cm)))
                   (Jmp next)
                   (Label ok))
          cm))]))
  

(define (compile-vec-helper p cm next i)
  (match p
    ;; empty list (p) edge case
    [(Vect '())
      (list (seq) cm)]

    [(Vect (cons p px))
      (match (compile-pattern p (cons #f cm) next)
        [(list i1 cm1)
          (match (compile-vec-helper (Vect px) cm1 next (+ 8 i))
            [(list i2 cm2)
              (list (seq (Push rax)
                         (Mov rax (Offset rax i))
                         i1
                         (Mov rax (Offset rsp (* 8 (- (sub1 (length cm1)) (length cm)))))
                         i2)
                cm2)])])]))

;; Id CEnv -> Integer
(define (lookup x cenv)
  (match cenv
    ['() (error "undefined variable:" x)]
    [(cons y rest)
     (match (eq? x y)
       [#t 0]
       [#f (+ 8 (lookup x rest))])]))
