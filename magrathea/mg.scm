;; magrathea helps you build planets
;;
;; it is a tiny tool designed to ease workflows in monorepos that are
;; modeled after the tvl depot.
;;
;; users familiar with workflows from other, larger monorepos may be
;; used to having a build tool that can work in any tree location.
;; magrathea enables this, but with nix-y monorepos.

(import (chicken base)
        (chicken format)
        (chicken irregex)
        (chicken port)
        (chicken process)
        (chicken process-context)
        (chicken string)
        (matchable))

(define usage #<<USAGE
usage: mg <command> [<target>]

target:
  a target specification with meaning inside of the repository. can
  be absolute (starting with //) or relative to the current directory
  (as long as said directory is inside of the repo). if no target is
  specified, the current directory's physical target is built.

  for example:

    //tools/magrathea - absolute physical target
    //foo/bar:baz     - absolute virtual target
    magrathea         - relative physical target
    :baz              - relative virtual target

commands:
  build - build a target
  shell - enter a shell with the target's build dependencies

file all feedback on b.tvl.fyi
USAGE
)

;; parse target definitions. trailing slashes on physical targets are
;; allowed for shell autocompletion.
;;
;; component ::= any string without "/" or ":"
;;
;; physical-target ::= <component>
;;                   | <component> "/"
;;                   | <component> "/" <physical-target>
;;
;; virtual-target ::= ":" <component>
;;
;; relative-target ::= <physical-target>
;;                   | <virtual-target>
;;                   | <physical-target> <virtual-target>
;;
;; root-anchor ::= "//"
;;
;; target ::= <relative-target> | <root-anchor> <relative-target>

;; read a path component until it looks like something else is coming
(define (read-component first port)
  (let ((keep-reading?
         (lambda () (not (or (eq? #\/ (peek-char port))
                             (eq? #\: (peek-char port))
                             (eof-object? (peek-char port)))))))
    (let reader ((acc (list first))
                 (condition (keep-reading?)))
      (if condition (reader (cons (read-char port) acc) (keep-reading?))
          (list->string (reverse acc))))))

;; read something that started with a slash. what will it be?
(define (read-slash port)
  (if (eq? #\/ (peek-char port))
      (begin (read-char port)
             'root-anchor)
      'path-separator))

;; read any target token and leave port sitting at the next one
(define (read-token port)
  (match (read-char port)
         [#\/ (read-slash port)]
         [#\: 'virtual-separator]
         [other (read-component other port)]))

;; read a target into a list of target tokens
(define (read-target target-str)
  (call-with-input-string
   target-str
   (lambda (port)
     (let reader ((acc '()))
       (if (eof-object? (peek-char port))
           (reverse acc)
           (reader (cons (read-token port) acc)))))))

(define-record target absolute components virtual)
(define-record-printer (target t out)
  (fprintf out (conc "#target("
                     (if (target-absolute t) "//" "")
                     (string-intersperse (target-components t) "/")
                     (if (target-virtual t) ":" "")
                     (or (target-virtual t) "")
                     ")")))

;; parse and validate a list of target tokens
(define parse-tokens
  (lambda (tokens #!optional (mode 'root) (acc (make-target #f '() #f)))
    (match (cons mode tokens)
           ;; absolute target
           [('root . ('root-anchor . rest))
            (begin (target-absolute-set! acc #t)
                   (parse-tokens rest 'root acc))]

           ;; relative target minus potential garbage
           [('root . (not ('path-separator . _)))
            (parse-tokens tokens 'normal acc)]

           ;; virtual target
           [('normal . ('virtual-separator . rest))
            (parse-tokens rest 'virtual acc)]

           [('virtual . ((? string? v)))
            (begin
              (target-virtual-set! acc v)
              acc)]

           ;; chomp through all components and separators
           [('normal . ('path-separator . rest)) (parse-tokens rest 'normal acc)]
           [('normal . ((? string? component) . rest))
            (begin (target-components-set! acc (append (target-components acc) (list component)))
                   (parse-tokens rest 'normal acc ))]

           ;; nothing more to parse and not in a weird state, all done, yay!
           [('normal . ()) acc]

           ;; oh no, we ran out of input too early :(
           [(_ . ()) `(error . ,(format "unexpected end of input while parsing ~s target" mode))]

           ;; something else was invalid :(
           [_ `(error . ,(format "unexpected ~s while parsing ~s target" (car tokens) mode))])))

(define (parse-target target)
  (parse-tokens (read-target target)))

;; return the current repository root as a string
(define mg--repository-root #f)
(define (repository-root)
  (or mg--repository-root
      (begin
        (set! mg--repository-root
              (string-chomp
               (call-with-input-pipe "git rev-parse --show-toplevel"
                                     (lambda (p) (read-string #f p)))))
        mg--repository-root)))

;; determine the current path relative to the root of the repository
;; and return it as a list of path components.
(define (relative-repo-path)
  (string-split
   (substring (current-directory) (string-length (repository-root))) "/"))

;; escape a string for interpolation in nix code
(define (nix-escape str)
  (string-translate* str '(("\"" . "\\\"")
                           ("${" . "\\${"))))

;; create a nix expression to build the attribute at the specified
;; components
;;
;; this uses builtins.getAttr explicitly to avoid problems with
;; escaping.
(define nix-expr-for
  (lambda (parts #!optional (acc (conc "(import " (repository-root) " {})")))
    (match parts
           [() (conc "with builtins; " acc)]
           [_ (nix-expr-for (cdr parts)
                            (conc "(getAttr \"" (nix-escape (car parts)) "\" " acc ")"))])))

(define (execute-build components)
  (let ((attr (string-intersperse components "."))
        (expr (nix-expr-for components)))
    (print "[mg] building attribute '" attr "'")
    (process-execute "nix-build" (list "-E" expr "--show-trace"))))

(define (build args)
  (match args
         ;; simplest case: plain mg build with no target spec -> build
         ;; the current folder's main target.
         [() (execute-build (relative-repo-path))]
         [other (print "not yet implemented")]))

(define (execute-shell components)
  (let ((attr (string-intersperse components "."))
        (expr (nix-expr-for components))
        (user-shell (or (get-environment-variable "SHELL") "bash")))
    (print "[mg] entering shell for '" attr "'")
    (process-execute "nix-shell"
                     (list "-E" expr "--command" user-shell))))

(define (shell args)
  (match args
         [() (execute-shell (relative-repo-path))]
         [other (print "not yet implemented")]))

(define (main args)
  (match args
         [() (print usage)]
         [("build" ...) (build (cdr args))]
         [("shell" ...) (shell (cdr args))]
         [other (begin (print "unknown command: mg " args)
                       (print usage))]))

(main (command-line-arguments))
