;; magrathea helps you build planets
;;
;; it is a tiny tool designed to ease workflows in monorepos that are
;; modeled after the tvl depot.
;;
;; users familiar with workflows from other, larger monorepos may be
;; used to having a build tool that can work in any tree location.
;; magrathea enables this, but with nix-y monorepos.

(import (chicken base)
        (chicken io)
        (chicken irregex)
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
