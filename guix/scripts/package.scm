;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2012, 2013 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2013 Nikita Karetnikov <nikita@karetnikov.org>
;;; Copyright © 2013 Mark H Weaver <mhw@netris.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix scripts package)
  #:use-module (guix ui)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (guix config)
  #:use-module (guix records)
  #:use-module ((guix build utils) #:select (directory-exists? mkdir-p))
  #:use-module ((guix ftp-client) #:select (ftp-open))
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 vlist)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26)
  #:use-module (srfi srfi-34)
  #:use-module (srfi srfi-37)
  #:use-module (gnu packages)
  #:use-module ((gnu packages base) #:select (guile-final))
  #:use-module ((gnu packages bootstrap) #:select (%bootstrap-guile))
  #:use-module (guix gnu-maintenance)
  #:export (guix-package))

(define %store
  (make-parameter #f))


;;;
;;; User profile.
;;;

(define %user-profile-directory
  (and=> (getenv "HOME")
         (cut string-append <> "/.guix-profile")))

(define %profile-directory
  (string-append (or (getenv "NIX_STATE_DIR") %state-directory) "/profiles/"
                 (or (and=> (getenv "USER")
                            (cut string-append "per-user/" <>))
                     "default")))

(define %current-profile
  ;; Call it `guix-profile', not `profile', to allow Guix profiles to
  ;; coexist with Nix profiles.
  (string-append %profile-directory "/guix-profile"))


;;;
;;; Manifests.
;;;

(define-record-type <manifest>
  (manifest entries)
  manifest?
  (entries manifest-entries))                     ; list of <manifest-entry>

;; Convenient alias, to avoid name clashes.
(define make-manifest manifest)

(define-record-type* <manifest-entry> manifest-entry
  make-manifest-entry
  manifest-entry?
  (name         manifest-entry-name)              ; string
  (version      manifest-entry-version)           ; string
  (output       manifest-entry-output             ; string
                (default "out"))
  (path         manifest-entry-path)              ; store path
  (dependencies manifest-entry-dependencies       ; list of store paths
                (default '())))

(define (profile-manifest profile)
  "Return the PROFILE's manifest."
  (let ((file (string-append profile "/manifest")))
    (if (file-exists? file)
        (call-with-input-file file read-manifest)
        (manifest '()))))

(define (manifest->sexp manifest)
  "Return a representation of MANIFEST as an sexp."
  (define (entry->sexp entry)
    (match entry
      (($ <manifest-entry> name version path output (deps ...))
       (list name version path output deps))))

  (match manifest
    (($ <manifest> (entries ...))
     `(manifest (version 1)
                (packages ,(map entry->sexp entries))))))

(define (sexp->manifest sexp)
  "Parse SEXP as a manifest."
  (match sexp
    (('manifest ('version 0)
                ('packages ((name version output path) ...)))
     (manifest
      (map (lambda (name version output path)
             (manifest-entry
              (name name)
              (version version)
              (output output)
              (path path)))
           name version output path)))

    ;; Version 1 adds a list of propagated inputs to the
    ;; name/version/output/path tuples.
    (('manifest ('version 1)
                ('packages ((name version output path deps) ...)))
     (manifest
      (map (lambda (name version output path deps)
             (manifest-entry
              (name name)
              (version version)
              (output output)
              (path path)
              (dependencies deps)))
           name version output path deps)))

    (_
     (error "unsupported manifest format" manifest))))

(define (read-manifest port)
  "Return the packages listed in MANIFEST."
  (sexp->manifest (read port)))

(define (write-manifest manifest port)
  "Write MANIFEST to PORT."
  (write (manifest->sexp manifest) port))

(define (remove-manifest-entry name lst)
  "Remove the manifest entry named NAME from LST."
  (remove (match-lambda
           (($ <manifest-entry> entry-name)
            (string=? name entry-name)))
          lst))

(define (manifest-remove manifest names)
  "Remove entries for each of NAMES from MANIFEST."
  (make-manifest (fold remove-manifest-entry
                       (manifest-entries manifest)
                       names)))

(define (manifest-installed? manifest name)
  "Return #t if MANIFEST has an entry for NAME, #f otherwise."
  (define (->bool x)
    (not (not x)))

  (->bool (find (match-lambda
                 (($ <manifest-entry> entry-name)
                  (string=? entry-name name)))
                (manifest-entries manifest))))


;;;
;;; Profiles.
;;;

(define (profile-regexp profile)
  "Return a regular expression that matches PROFILE's name and number."
  (make-regexp (string-append "^" (regexp-quote (basename profile))
                              "-([0-9]+)")))

(define (generation-numbers profile)
  "Return the sorted list of generation numbers of PROFILE, or '(0) if no
former profiles were found."
  (define* (scandir name #:optional (select? (const #t))
                    (entry<? (@ (ice-9 i18n) string-locale<?)))
    ;; XXX: Bug-fix version introduced in Guile v2.0.6-62-g139ce19.
    (define (enter? dir stat result)
      (and stat (string=? dir name)))

    (define (visit basename result)
      (if (select? basename)
          (cons basename result)
          result))

    (define (leaf name stat result)
      (and result
           (visit (basename name) result)))

    (define (down name stat result)
      (visit "." '()))

    (define (up name stat result)
      (visit ".." result))

    (define (skip name stat result)
      ;; All the sub-directories are skipped.
      (visit (basename name) result))

    (define (error name* stat errno result)
      (if (string=? name name*)             ; top-level NAME is unreadable
          result
          (visit (basename name*) result)))

    (and=> (file-system-fold enter? leaf down up skip error #f name lstat)
           (lambda (files)
             (sort files entry<?))))

  (match (scandir (dirname profile)
                  (cute regexp-exec (profile-regexp profile) <>))
    (#f                                         ; no profile directory
     '(0))
    (()                                         ; no profiles
     '(0))
    ((profiles ...)                             ; former profiles around
     (sort (map (compose string->number
                         (cut match:substring <> 1)
                         (cute regexp-exec (profile-regexp profile) <>))
                profiles)
           <))))

(define (previous-generation-number profile number)
  "Return the number of the generation before generation NUMBER of
PROFILE, or 0 if none exists.  It could be NUMBER - 1, but it's not the
case when generations have been deleted (there are \"holes\")."
  (fold (lambda (candidate highest)
          (if (and (< candidate number) (> candidate highest))
              candidate
              highest))
        0
        (generation-numbers profile)))

(define (profile-derivation store manifest)
  "Return a derivation that builds a profile (aka. 'user environment') with
the given MANIFEST."
  (define builder
    `(begin
       (use-modules (ice-9 pretty-print)
                    (guix build union))

       (setvbuf (current-output-port) _IOLBF)
       (setvbuf (current-error-port) _IOLBF)

       (let ((output (assoc-ref %outputs "out"))
             (inputs (map cdr %build-inputs)))
         (format #t "building profile `~a' with ~a packages...~%"
                 output (length inputs))
         (union-build output inputs)
         (call-with-output-file (string-append output "/manifest")
           (lambda (p)
             (pretty-print ',(manifest->sexp manifest) p))))))

  (define ensure-valid-input
    ;; If a package object appears in the given input, turn it into a
    ;; derivation path.
    (match-lambda
     ((name (? package? p) sub-drv ...)
      `(,name ,(package-derivation (%store) p) ,@sub-drv))
     (input
      input)))

  (build-expression->derivation store "profile"
                                (%current-system)
                                builder
                                (append-map (match-lambda
                                             (($ <manifest-entry> name version
                                                 output path deps)
                                              `((,name ,path)
                                                ,@(map ensure-valid-input
                                                       deps))))
                                            (manifest-entries manifest))
                                #:modules '((guix build union))))

(define (generation-number profile)
  "Return PROFILE's number or 0.  An absolute file name must be used."
  (or (and=> (false-if-exception (regexp-exec (profile-regexp profile)
                                              (basename (readlink profile))))
             (compose string->number (cut match:substring <> 1)))
      0))

(define (link-to-empty-profile generation)
  "Link GENERATION, a string, to the empty profile."
  (let* ((drv  (profile-derivation (%store) (manifest '())))
         (prof (derivation->output-path drv "out")))
    (when (not (build-derivations (%store) (list drv)))
          (leave (_ "failed to build the empty profile~%")))

    (switch-symlinks generation prof)))

(define (switch-to-previous-generation profile)
  "Atomically switch PROFILE to the previous generation."
  (let* ((number              (generation-number profile))
         (previous-number     (previous-generation-number profile number))
         (previous-generation (format #f "~a-~a-link"
                                      profile previous-number)))
    (format #t (_ "switching from generation ~a to ~a~%")
            number previous-number)
    (switch-symlinks profile previous-generation)))

(define (roll-back profile)
  "Roll back to the previous generation of PROFILE."
  (let* ((number              (generation-number profile))
         (previous-number     (previous-generation-number profile number))
         (previous-generation (format #f "~a-~a-link"
                                      profile previous-number))
         (manifest            (string-append previous-generation "/manifest")))
    (cond ((not (file-exists? profile))                 ; invalid profile
           (leave (_ "profile '~a' does not exist~%")
                  profile))
          ((zero? number)                               ; empty profile
           (format (current-error-port)
                   (_ "nothing to do: already at the empty profile~%")))
          ((or (zero? previous-number)                  ; going to emptiness
               (not (file-exists? previous-generation)))
           (link-to-empty-profile previous-generation)
           (switch-to-previous-generation profile))
          (else
           (switch-to-previous-generation profile)))))  ; anything else

(define (generation-time profile number)
  "Return the creation time of a generation in the UTC format."
  (make-time time-utc 0
             (stat:ctime (stat (format #f "~a-~a-link" profile number)))))

(define* (matching-generations str #:optional (profile %current-profile)
                               #:key (duration-relation <=))
  "Return the list of available generations matching a pattern in STR.  See
'string->generations' and 'string->duration' for the list of valid patterns.
When STR is a duration pattern, return all the generations whose ctime has
DURATION-RELATION with the current time."
  (define (valid-generations lst)
    (define (valid-generation? n)
      (any (cut = n <>) (generation-numbers profile)))

    (fold-right (lambda (x acc)
                  (if (valid-generation? x)
                      (cons x acc)
                      acc))
                '()
                lst))

  (define (filter-generations generations)
    (match generations
      (() '())
      (('>= n)
       (drop-while (cut > n <>)
                   (generation-numbers profile)))
      (('<= n)
       (valid-generations (iota n 1)))
      ((lst ..1)
       (valid-generations lst))
      (_ #f)))

  (define (filter-by-duration duration)
    (define (time-at-midnight time)
      ;; Return TIME at midnight by setting nanoseconds, seconds, minutes, and
      ;; hours to zeros.
      (let ((d (time-utc->date time)))
         (date->time-utc
          (make-date 0 0 0 0
                     (date-day d) (date-month d)
                     (date-year d) (date-zone-offset d)))))

    (define generation-ctime-alist
      (map (lambda (number)
             (cons number
                   (time-second
                    (time-at-midnight
                     (generation-time profile number)))))
           (generation-numbers profile)))

    (match duration
      (#f #f)
      (res
       (let ((s (time-second
                 (subtract-duration (time-at-midnight (current-time))
                                    duration))))
         (delete #f (map (lambda (x)
                           (and (duration-relation s (cdr x))
                                (first x)))
                         generation-ctime-alist))))))

  (cond ((string->generations str)
         =>
         filter-generations)
        ((string->duration str)
         =>
         filter-by-duration)
        (else #f)))

(define (find-packages-by-description rx)
  "Return the list of packages whose name, synopsis, or description matches
RX."
  (define (same-location? p1 p2)
    ;; Compare locations of two packages.
    (equal? (package-location p1) (package-location p2)))

  (delete-duplicates
   (sort
    (fold-packages (lambda (package result)
                     (define matches?
                       (cut regexp-exec rx <>))

                     (if (or (matches? (gettext (package-name package)))
                             (and=> (package-synopsis package)
                                    (compose matches? gettext))
                             (and=> (package-description package)
                                    (compose matches? gettext)))
                         (cons package result)
                         result))
                   '())
    (lambda (p1 p2)
      (string<? (package-name p1)
                (package-name p2))))
   same-location?))

(define (input->name+path input)
  "Convert the name/package/sub-drv tuple INPUT to a name/store-path tuple."
  (let loop ((input input))
    (match input
      ((name (? package? package))
       (loop `(,name ,package "out")))
      ((name (? package? package) sub-drv)
       `(,name ,(package-output (%store) package sub-drv)))
      (_
       input))))

(define %sigint-prompt
  ;; The prompt to jump to upon SIGINT.
  (make-prompt-tag "interruptible"))

(define (call-with-sigint-handler thunk handler)
  "Call THUNK and return its value.  Upon SIGINT, call HANDLER with the signal
number in the context of the continuation of the call to this function, and
return its return value."
  (call-with-prompt %sigint-prompt
                    (lambda ()
                      (sigaction SIGINT
                        (lambda (signum)
                          (sigaction SIGINT SIG_DFL)
                          (abort-to-prompt %sigint-prompt signum)))
                      (dynamic-wind
                        (const #t)
                        thunk
                        (cut sigaction SIGINT SIG_DFL)))
                    (lambda (k signum)
                      (handler signum))))

(define-syntax-rule (waiting exp fmt rest ...)
  "Display the given message while EXP is being evaluated."
  (let* ((message (format #f fmt rest ...))
         (blank   (make-string (string-length message) #\space)))
    (display message (current-error-port))
    (force-output (current-error-port))
    (call-with-sigint-handler
     (lambda ()
       (dynamic-wind
         (const #f)
         (lambda () exp)
         (lambda ()
           ;; Clear the line.
           (display #\cr (current-error-port))
           (display blank (current-error-port))
           (display #\cr (current-error-port))
           (force-output (current-error-port)))))
     (lambda (signum)
       (format (current-error-port) "  interrupted by signal ~a~%" SIGINT)
       #f))))


;;;
;;; Package specifications.
;;;

(define newest-available-packages
  (memoize find-newest-available-packages))

(define (find-best-packages-by-name name version)
  "If version is #f, return the list of packages named NAME with the highest
version numbers; otherwise, return the list of packages named NAME and at
VERSION."
  (if version
      (find-packages-by-name name version)
      (match (vhash-assoc name (newest-available-packages))
        ((_ version pkgs ...) pkgs)
        (#f '()))))

(define* (specification->package+output spec #:optional (output "out"))
  "Find the package and output specified by SPEC, or #f and #f; SPEC may
optionally contain a version number and an output name, as in these examples:

  guile
  guile-2.0.9
  guile:debug
  guile-2.0.9:debug

If SPEC does not specify a version number, return the preferred newest
version; if SPEC does not specify an output, return OUTPUT."
  (define (ensure-output p sub-drv)
    (if (member sub-drv (package-outputs p))
        sub-drv
        (leave (_ "package `~a' lacks output `~a'~%")
               (package-full-name p)
               sub-drv)))

  (let*-values (((name sub-drv)
                 (match (string-rindex spec #\:)
                   (#f    (values spec output))
                   (colon (values (substring spec 0 colon)
                                  (substring spec (+ 1 colon))))))
                ((name version)
                 (package-name->name+version name)))
    (match (find-best-packages-by-name name version)
      ((p)
       (values p (ensure-output p sub-drv)))
      ((p p* ...)
       (warning (_ "ambiguous package specification `~a'~%")
                spec)
       (warning (_ "choosing ~a from ~a~%")
                (package-full-name p)
                (location->string (package-location p)))
       (values p (ensure-output p sub-drv)))
      (()
       (leave (_ "~a: package not found~%") spec)))))

(define (upgradeable? name current-version current-path)
  "Return #t if there's a version of package NAME newer than CURRENT-VERSION,
or if the newest available version is equal to CURRENT-VERSION but would have
an output path different than CURRENT-PATH."
  (match (vhash-assoc name (newest-available-packages))
    ((_ candidate-version pkg . rest)
     (case (version-compare candidate-version current-version)
       ((>) #t)
       ((<) #f)
       ((=) (let ((candidate-path (derivation->output-path
                                   (package-derivation (%store) pkg))))
              (not (string=? current-path candidate-path))))))
    (#f #f)))

(define ftp-open*
  ;; Memoizing version of `ftp-open'.  The goal is to avoid initiating a new
  ;; FTP connection for each package, esp. since most of them are to the same
  ;; server.  This has a noticeable impact when doing "guix upgrade -u".
  (memoize ftp-open))

(define (check-package-freshness package)
  "Check whether PACKAGE has a newer version available upstream, and report
it."
  ;; TODO: Automatically inject the upstream version when desired.

  (catch #t
    (lambda ()
      (when (false-if-exception (gnu-package? package))
        (let ((name      (package-name package))
              (full-name (package-full-name package)))
          (match (waiting (latest-release name
                                          #:ftp-open ftp-open*
                                          #:ftp-close (const #f))
                          (_ "looking for the latest release of GNU ~a...") name)
            ((latest-version . _)
             (when (version>? latest-version full-name)
               (format (current-error-port)
                       (_ "~a: note: using ~a \
but ~a is available upstream~%")
                       (location->string (package-location package))
                       full-name latest-version)))
            (_ #t)))))
    (lambda (key . args)
      ;; Silently ignore networking errors rather than preventing
      ;; installation.
      (case key
        ((getaddrinfo-error ftp-error) #f)
        (else (apply throw key args))))))


;;;
;;; Search paths.
;;;

(define* (search-path-environment-variables entries profile
                                            #:optional (getenv getenv))
  "Return environment variable definitions that may be needed for the use of
ENTRIES, a list of manifest entries, in PROFILE.  Use GETENV to determine the
current settings and report only settings not already effective."

  ;; Prefer ~/.guix-profile to the real profile directory name.
  (let ((profile (if (and %user-profile-directory
                          (false-if-exception
                           (string=? (readlink %user-profile-directory)
                                     profile)))
                     %user-profile-directory
                     profile)))

    ;; The search path info is not stored in the manifest.  Thus, we infer the
    ;; search paths from same-named packages found in the distro.

    (define manifest-entry->package
      (match-lambda
       (($ <manifest-entry> name version)
        (match (append (find-packages-by-name name version)
                       (find-packages-by-name name))
          ((p _ ...) p)
          (_ #f)))))

    (define search-path-definition
      (match-lambda
       (($ <search-path-specification> variable directories separator)
        (let ((values      (or (and=> (getenv variable)
                                      (cut string-tokenize* <> separator))
                               '()))
              (directories (filter file-exists?
                                   (map (cut string-append profile
                                             "/" <>)
                                        directories))))
          (if (every (cut member <> values) directories)
              #f
              (format #f "export ~a=\"~a\""
                      variable
                      (string-join directories separator)))))))

    (let* ((packages     (filter-map manifest-entry->package entries))
           (search-paths (delete-duplicates
                          (append-map package-native-search-paths
                                      packages))))
      (filter-map search-path-definition search-paths))))

(define (display-search-paths entries profile)
  "Display the search path environment variables that may need to be set for
ENTRIES, a list of manifest entries, in the context of PROFILE."
  (let ((settings (search-path-environment-variables entries profile)))
    (unless (null? settings)
      (format #t (_ "The following environment variable definitions may be needed:~%"))
      (format #t "~{   ~a~%~}" settings))))


;;;
;;; Command-line options.
;;;

(define %default-options
  ;; Alist of default option values.
  `((profile . ,%current-profile)
    (max-silent-time . 3600)
    (substitutes? . #t)))

(define (show-help)
  (display (_ "Usage: guix package [OPTION]... PACKAGES...
Install, remove, or upgrade PACKAGES in a single transaction.\n"))
  (display (_ "
  -i, --install=PACKAGE  install PACKAGE"))
  (display (_ "
  -e, --install-from-expression=EXP
                         install the package EXP evaluates to"))
  (display (_ "
  -r, --remove=PACKAGE   remove PACKAGE"))
  (display (_ "
  -u, --upgrade[=REGEXP] upgrade all the installed packages matching REGEXP"))
  (display (_ "
      --roll-back        roll back to the previous generation"))
  (display (_ "
      --search-paths     display needed environment variable definitions"))
  (display (_ "
  -l, --list-generations[=PATTERN]
                         list generations matching PATTERN"))
  (display (_ "
  -d, --delete-generations[=PATTERN]
                         delete generations matching PATTERN"))
  (newline)
  (display (_ "
  -p, --profile=PROFILE  use PROFILE instead of the user's default profile"))
  (display (_ "
  -n, --dry-run          show what would be done without actually doing it"))
  (display (_ "
      --fallback         fall back to building when the substituter fails"))
  (display (_ "
      --no-substitutes   build instead of resorting to pre-built substitutes"))
  (display (_ "
      --max-silent-time=SECONDS
                         mark the build as failed after SECONDS of silence"))
  (display (_ "
      --bootstrap        use the bootstrap Guile to build the profile"))
  (display (_ "
      --verbose          produce verbose output"))
  (newline)
  (display (_ "
  -s, --search=REGEXP    search in synopsis and description using REGEXP"))
  (display (_ "
  -I, --list-installed[=REGEXP]
                         list installed packages matching REGEXP"))
  (display (_ "
  -A, --list-available[=REGEXP]
                         list available packages matching REGEXP"))
  (newline)
  (display (_ "
  -h, --help             display this help and exit"))
  (display (_ "
  -V, --version          display version information and exit"))
  (newline)
  (show-bug-report-information))

(define %options
  ;; Specification of the command-line options.
  (list (option '(#\h "help") #f #f
                (lambda args
                  (show-help)
                  (exit 0)))
        (option '(#\V "version") #f #f
                (lambda args
                  (show-version-and-exit "guix package")))

        (option '(#\i "install") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'install arg result)))
        (option '(#\e "install-from-expression") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'install (read/eval-package-expression arg)
                              result)))
        (option '(#\r "remove") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'remove arg result)))
        (option '(#\u "upgrade") #f #t
                (lambda (opt name arg result)
                  (alist-cons 'upgrade arg result)))
        (option '("roll-back") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'roll-back? #t result)))
        (option '(#\l "list-generations") #f #t
                (lambda (opt name arg result)
                  (cons `(query list-generations ,(or arg ""))
                        result)))
        (option '(#\d "delete-generations") #f #t
                (lambda (opt name arg result)
                  (alist-cons 'delete-generations (or arg "")
                              result)))
        (option '("search-paths") #f #f
                (lambda (opt name arg result)
                  (cons `(query search-paths) result)))
        (option '(#\p "profile") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'profile arg
                              (alist-delete 'profile result))))
        (option '(#\n "dry-run") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'dry-run? #t result)))
        (option '("fallback") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'fallback? #t
                              (alist-delete 'fallback? result))))
        (option '("no-substitutes") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'substitutes? #f
                              (alist-delete 'substitutes? result))))
        (option '("max-silent-time") #t #f
                (lambda (opt name arg result)
                  (alist-cons 'max-silent-time (string->number* arg)
                              result)))
        (option '("bootstrap") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'bootstrap? #t result)))
        (option '("verbose") #f #f
                (lambda (opt name arg result)
                  (alist-cons 'verbose? #t result)))
        (option '(#\s "search") #t #f
                (lambda (opt name arg result)
                  (cons `(query search ,(or arg ""))
                        result)))
        (option '(#\I "list-installed") #f #t
                (lambda (opt name arg result)
                  (cons `(query list-installed ,(or arg ""))
                        result)))
        (option '(#\A "list-available") #f #t
                (lambda (opt name arg result)
                  (cons `(query list-available ,(or arg ""))
                        result)))))

(define (options->installable opts manifest)
  "Given MANIFEST, the current manifest, and OPTS, the result of 'args-fold',
return two values: the new list of manifest entries, and the list of
derivations that need to be built."
  (define (canonicalize-deps deps)
    ;; Remove duplicate entries from DEPS, a list of propagated inputs,
    ;; where each input is a name/path tuple, and replace package objects with
    ;; store paths.
    (define (same? d1 d2)
      (match d1
        ((_ p1)
         (match d2
           ((_ p2) (eq? p1 p2))
           (_      #f)))
        ((_ p1 out1)
         (match d2
           ((_ p2 out2)
            (and (string=? out1 out2)
                 (eq? p1 p2)))
           (_ #f)))))

    (map (match-lambda
          ((name package)
           (list name (package-output (%store) package)))
          ((name package output)
           (list name (package-output (%store) package output))))
         (delete-duplicates deps same?)))

  (define (package->manifest-entry p output)
    ;; Return a manifest entry for the OUTPUT of package P.
    (check-package-freshness p)
    ;; When given a package via `-e', install the first of its
    ;; outputs (XXX).
    (let* ((output (or output (car (package-outputs p))))
           (path   (package-output (%store) p output))
           (deps   (package-transitive-propagated-inputs p)))
      (manifest-entry
       (name (package-name p))
       (version (package-version p))
       (output output)
       (path path)
       (dependencies (canonicalize-deps deps)))))

  (define upgrade-regexps
    (filter-map (match-lambda
                 (('upgrade . regexp)
                  (make-regexp (or regexp "")))
                 (_ #f))
                opts))

  (define packages-to-upgrade
    (match upgrade-regexps
      (()
       '())
      ((_ ...)
       (let ((newest (find-newest-available-packages)))
         (filter-map (match-lambda
                      (($ <manifest-entry> name version output path _)
                       (and (any (cut regexp-exec <> name)
                                 upgrade-regexps)
                            (upgradeable? name version path)
                            (let ((output (or output "out")))
                              (call-with-values
                                  (lambda ()
                                    (specification->package+output name output))
                                list))))
                      (_ #f))
                     (manifest-entries manifest))))))

  (define to-upgrade
    (map (match-lambda
          ((package output)
           (package->manifest-entry package output)))
         packages-to-upgrade))

  (define packages-to-install
    (filter-map (match-lambda
                 (('install . (? package? p))
                  (list p "out"))
                 (('install . (? string? spec))
                  (and (not (store-path? spec))
                       (let-values (((package output)
                                     (specification->package+output spec)))
                         (and package (list package output)))))
                 (_ #f))
                opts))

  (define to-install
    (append (map (match-lambda
                  ((package output)
                   (package->manifest-entry package output)))
                 packages-to-install)
            (filter-map (match-lambda
                         (('install . (? package?))
                          #f)
                         (('install . (? store-path? path))
                          (let-values (((name version)
                                        (package-name->name+version
                                         (store-path-package-name path))))
                            (manifest-entry
                             (name name)
                             (version version)
                             (output #f)
                             (path path))))
                         (_ #f))
                        opts)))

  (define derivations
    (map (match-lambda
          ((package output)
           ;; FIXME: We should really depend on just OUTPUT rather than on all
           ;; the outputs of PACKAGE.
           (package-derivation (%store) package)))
         (append packages-to-install packages-to-upgrade)))

  (values (append to-upgrade to-install) derivations))


;;;
;;; Entry point.
;;;

(define (guix-package . args)
  (define (parse-options)
    ;; Return the alist of option values.
    (args-fold* args %options
                (lambda (opt name arg result)
                  (leave (_ "~A: unrecognized option~%") name))
                (lambda (arg result)
                  (leave (_ "~A: extraneous argument~%") arg))
                %default-options))

  (define (guile-missing?)
    ;; Return #t if %GUILE-FOR-BUILD is not available yet.
    (let ((out (derivation->output-path (%guile-for-build))))
      (not (valid-path? (%store) out))))

  (define (ensure-default-profile)
    ;; Ensure the default profile symlink and directory exist and are
    ;; writable.

    (define (rtfm)
      (format (current-error-port)
              (_ "Try \"info '(guix) Invoking guix package'\" for \
more information.~%"))
      (exit 1))

    ;; Create ~/.guix-profile if it doesn't exist yet.
    (when (and %user-profile-directory
               %current-profile
               (not (false-if-exception
                     (lstat %user-profile-directory))))
      (symlink %current-profile %user-profile-directory))

    (let ((s (stat %profile-directory #f)))
      ;; Attempt to create /…/profiles/per-user/$USER if needed.
      (unless (and s (eq? 'directory (stat:type s)))
        (catch 'system-error
          (lambda ()
            (mkdir-p %profile-directory))
          (lambda args
            ;; Often, we cannot create %PROFILE-DIRECTORY because its
            ;; parent directory is root-owned and we're running
            ;; unprivileged.
            (format (current-error-port)
                    (_ "error: while creating directory `~a': ~a~%")
                    %profile-directory
                    (strerror (system-error-errno args)))
            (format (current-error-port)
                    (_ "Please create the `~a' directory, with you as the owner.~%")
                    %profile-directory)
            (rtfm))))

      ;; Bail out if it's not owned by the user.
      (unless (or (not s) (= (stat:uid s) (getuid)))
        (format (current-error-port)
                (_ "error: directory `~a' is not owned by you~%")
                %profile-directory)
        (format (current-error-port)
                (_ "Please change the owner of `~a' to user ~s.~%")
                %profile-directory (or (getenv "USER") (getuid)))
        (rtfm))))

  (define (process-actions opts)
    ;; Process any install/remove/upgrade action from OPTS.

    (define dry-run? (assoc-ref opts 'dry-run?))
    (define verbose? (assoc-ref opts 'verbose?))
    (define profile  (assoc-ref opts 'profile))

    (define (same-package? entry name output)
      (match entry
        (($ <manifest-entry> entry-name _ entry-output _ ...)
         (and (equal? name entry-name)
              (equal? output entry-output)))))

    (define (show-what-to-remove/install remove install dry-run?)
      ;; Tell the user what's going to happen in high-level terms.
      ;; TODO: Report upgrades more clearly.
      (match remove
        ((($ <manifest-entry> name version _ path _) ..1)
         (let ((len    (length name))
               (remove (map (cut format #f "  ~a-~a\t~a" <> <> <>)
                            name version path)))
           (if dry-run?
               (format (current-error-port)
                       (N_ "The following package would be removed:~% ~{~a~%~}~%"
                           "The following packages would be removed:~% ~{~a~%~}~%"
                           len)
                       remove)
               (format (current-error-port)
                       (N_ "The following package will be removed:~% ~{~a~%~}~%"
                           "The following packages will be removed:~% ~{~a~%~}~%"
                           len)
                       remove))))
        (_ #f))
      (match install
        ((($ <manifest-entry> name version output path _) ..1)
         (let ((len     (length name))
               (install (map (cut format #f "   ~a-~a\t~a\t~a" <> <> <> <>)
                             name version output path)))
           (if dry-run?
               (format (current-error-port)
                       (N_ "The following package would be installed:~%~{~a~%~}~%"
                           "The following packages would be installed:~%~{~a~%~}~%"
                           len)
                       install)
               (format (current-error-port)
                       (N_ "The following package will be installed:~%~{~a~%~}~%"
                           "The following packages will be installed:~%~{~a~%~}~%"
                           len)
                       install))))
        (_ #f)))

    (define current-generation-number
      (generation-number profile))

    (define (display-and-delete number)
      (let ((generation (format #f "~a-~a-link" profile number)))
        (unless (zero? number)
          (format #t (_ "deleting ~a~%") generation)
          (delete-file generation))))

    (define (delete-generation number)
      (let* ((previous-number (previous-generation-number profile number))
             (previous-generation (format #f "~a-~a-link"
                                          profile previous-number)))
        (cond ((zero? number))  ; do not delete generation 0
              ((and (= number current-generation-number)
                    (not (file-exists? previous-generation)))
               (link-to-empty-profile previous-generation)
               (switch-to-previous-generation profile)
               (display-and-delete number))
              ((= number current-generation-number)
               (roll-back profile)
               (display-and-delete number))
              (else
               (display-and-delete number)))))

    ;; First roll back if asked to.
    (cond ((and (assoc-ref opts 'roll-back?) (not dry-run?))
           (begin
             (roll-back profile)
             (process-actions (alist-delete 'roll-back? opts))))
          ((and (assoc-ref opts 'delete-generations)
                (not dry-run?))
           (filter-map
            (match-lambda
             (('delete-generations . pattern)
              (cond ((not (file-exists? profile)) ; XXX: race condition
                     (leave (_ "profile '~a' does not exist~%")
                            profile))
                    ((string-null? pattern)
                     (let ((numbers (generation-numbers profile)))
                       (if (equal? numbers '(0))
                           (exit 0)
                           (for-each display-and-delete
                                     (delete current-generation-number
                                             numbers)))))
                    ;; Do not delete the zeroth generation.
                    ((equal? 0 (string->number pattern))
                     (exit 0))

                    ;; If PATTERN is a duration, match generations that are
                    ;; older than the specified duration.
                    ((matching-generations pattern profile
                                           #:duration-relation >)
                     =>
                     (lambda (numbers)
                       (if (null-list? numbers)
                           (exit 1)
                           (for-each delete-generation numbers))))
                    (else
                     (leave (_ "invalid syntax: ~a~%")
                            pattern)))

              (process-actions
               (alist-delete 'delete-generations opts)))
             (_ #f))
            opts))
          (else
           (let*-values (((manifest)
                          (profile-manifest profile))
                         ((install* drv)
                          (options->installable opts manifest)))
             (let* ((remove  (filter-map (match-lambda
                                          (('remove . package)
                                           package)
                                          (_ #f))
                                         opts))
                    (remove* (filter (cut manifest-installed? manifest <>)
                                     remove))
                    (entries
                     (append install*
                             (fold (lambda (package result)
                                     (match package
                                       (($ <manifest-entry> name _ out _ ...)
                                        (filter (negate
                                                 (cut same-package? <>
                                                      name out))
                                                result))))
                                   (manifest-entries
                                    (manifest-remove manifest remove))
                                   install*))))

               (when (equal? profile %current-profile)
                 (ensure-default-profile))

               (show-what-to-remove/install remove* install* dry-run?)
               (show-what-to-build (%store) drv
                                   #:use-substitutes? (assoc-ref opts 'substitutes?)
                                   #:dry-run? dry-run?)

               (or dry-run?
                   (and (build-derivations (%store) drv)
                        (let* ((prof-drv (profile-derivation (%store)
                                                             (make-manifest
                                                              entries)))
                               (prof     (derivation->output-path prof-drv))
                               (old-drv  (profile-derivation
                                          (%store) (profile-manifest profile)))
                               (old-prof (derivation->output-path old-drv))
                               (number   (generation-number profile))

                               ;; Always use NUMBER + 1 for the new profile,
                               ;; possibly overwriting a "previous future
                               ;; generation".
                               (name     (format #f "~a-~a-link"
                                                 profile (+ 1 number))))
                          (if (string=? old-prof prof)
                              (when (or (pair? install*) (pair? remove))
                                (format (current-error-port)
                                        (_ "nothing to be done~%")))
                              (and (parameterize ((current-build-output-port
                                                   ;; Output something when Guile
                                                   ;; needs to be built.
                                                   (if (or verbose? (guile-missing?))
                                                       (current-error-port)
                                                       (%make-void-port "w"))))
                                     (build-derivations (%store) (list prof-drv)))
                                   (let ((count (length entries)))
                                     (switch-symlinks name prof)
                                     (switch-symlinks profile name)
                                     (format #t (N_ "~a package in profile~%"
                                                    "~a packages in profile~%"
                                                    count)
                                             count)
                                     (display-search-paths entries
                                                           profile))))))))))))

  (define (process-query opts)
    ;; Process any query specified by OPTS.  Return #t when a query was
    ;; actually processed, #f otherwise.
    (let ((profile  (assoc-ref opts 'profile)))
      (match (assoc-ref opts 'query)
        (('list-generations pattern)
         (define (list-generation number)
           (unless (zero? number)
             (let ((header (format #f (_ "Generation ~a\t~a") number
                                   (date->string
                                    (time-utc->date
                                     (generation-time profile number))
                                    "~b ~d ~Y ~T")))
                   (current (generation-number profile)))
               (if (= number current)
                   (format #t (_ "~a\t(current)~%") header)
                   (format #t "~a~%" header)))
             (for-each (match-lambda
                        (($ <manifest-entry> name version output location _)
                         (format #t "  ~a\t~a\t~a\t~a~%"
                                 name version output location)))

                       ;; Show most recently installed packages last.
                       (reverse
                        (manifest-entries
                         (profile-manifest
                          (format #f "~a-~a-link" profile number)))))
             (newline)))

         (cond ((not (file-exists? profile)) ; XXX: race condition
                (leave (_ "profile '~a' does not exist~%")
                       profile))
               ((string-null? pattern)
                (let ((numbers (generation-numbers profile)))
                  (if (equal? numbers '(0))
                      (exit 0)
                      (for-each list-generation numbers))))
               ((matching-generations pattern profile)
                =>
                (lambda (numbers)
                  (if (null-list? numbers)
                      (exit 1)
                      (for-each list-generation numbers))))
               (else
                (leave (_ "invalid syntax: ~a~%")
                       pattern)))
         #t)

        (('list-installed regexp)
         (let* ((regexp    (and regexp (make-regexp regexp)))
                (manifest  (profile-manifest profile))
                (installed (manifest-entries manifest)))
           (for-each (match-lambda
                      (($ <manifest-entry> name version output path _)
                       (when (or (not regexp)
                                 (regexp-exec regexp name))
                         (format #t "~a\t~a\t~a\t~a~%"
                                 name (or version "?") output path))))

                     ;; Show most recently installed packages last.
                     (reverse installed))
           #t))

        (('list-available regexp)
         (let* ((regexp    (and regexp (make-regexp regexp)))
                (available (fold-packages
                            (lambda (p r)
                              (let ((n (package-name p)))
                                (if regexp
                                    (if (regexp-exec regexp n)
                                        (cons p r)
                                        r)
                                    (cons p r))))
                            '())))
           (for-each (lambda (p)
                       (format #t "~a\t~a\t~a\t~a~%"
                               (package-name p)
                               (package-version p)
                               (string-join (package-outputs p) ",")
                               (location->string (package-location p))))
                     (sort available
                           (lambda (p1 p2)
                             (string<? (package-name p1)
                                       (package-name p2)))))
           #t))

        (('search regexp)
         (let ((regexp (make-regexp regexp regexp/icase)))
           (for-each (cute package->recutils <> (current-output-port))
                     (find-packages-by-description regexp))
           #t))

        (('search-paths)
         (let* ((manifest (profile-manifest profile))
                (entries  (manifest-entries manifest))
                (packages (map manifest-entry-name entries))
                (settings (search-path-environment-variables entries profile
                                                             (const #f))))
           (format #t "~{~a~%~}" settings)
           #t))

        (_ #f))))

  (let ((opts (parse-options)))
    (or (process-query opts)
        (with-error-handling
          (parameterize ((%store (open-connection)))
            (set-build-options (%store)
                               #:fallback? (assoc-ref opts 'fallback?)
                               #:use-substitutes?
                               (assoc-ref opts 'substitutes?)
                               #:max-silent-time
                               (assoc-ref opts 'max-silent-time))

            (parameterize ((%guile-for-build
                            (package-derivation (%store)
                                                (if (assoc-ref opts 'bootstrap?)
                                                    %bootstrap-guile
                                                    guile-final))))
              (process-actions opts)))))))
