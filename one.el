;;; one.el --- assimilate Emacs packages as Git submodules  -*- lexical-binding: t -*-

;; Copyright (C) 2016-2021  Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Homepage: https://github.com/emacscollective/one
;; Keywords: tools

;; Package-Version: 3.2.0
;; Package-Requires: ((emacs "26") (epkg "3.3.0") (magit "3.0.0"))
;;
;;   One itself does no actually require Emacs 26 and has no
;;   other dependencies but when it is installed from Melpa,
;;   then it includes `one-elpa' and that requires Emacs 26
;;   and Epkg.

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; For a full copy of the GNU GPL see http://www.gnu.org/licenses.

;; This file contains code from GNU Emacs, which is
;; Copyright (C) 1976-2016 Free Software Foundation, Inc.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The One assimilate Emacs packages as Git submodules.  One is
;; an alternative, bare-bones profile manager for Emacs packages.

;; Please consult the manual for more information:
;; https://www.emacsmirror.net/manual/one.

;; One can be used by itself or alongside `package.el'.  In the
;; latter case One itself should be installed from Melpa, which
;; is still experimental and not yet covered in the manual.  See
;; https://github.com/emacscollective/one/issues/46 for now.

;;; Code:

(require 'autoload)
(require 'bytecomp)
(require 'cl-lib)
(require 'info)
(require 'pcase)
(require 'subr-x)

(eval-when-compile
  (require 'epkg nil t))
(declare-function eieio-oref        "eieio-core" (obj slot))
(declare-function epkg                    "epkg" (name))
(declare-function epkgs                   "epkg" (&optional select predicates))
(declare-function ePkg-git-package-p      "epkg" (obj))
(declare-function ePkg-github-package-p   "epkg" (obj))
(declare-function ePkg-gitlab-package-p   "epkg" (obj))
(declare-function ePkg-orphaned-package-p "epkg" (obj))
(declare-function ePkg-read-package       "epkg" (prompt &optional default))
(declare-function format-spec      "format-spec" (format specification))
(declare-function magit-get             "magit-git" (&rest keys))
(declare-function magit-get-some-remote "magit-git" (&optional branch))

(defvar git-commit-mode-map)
(defvar compilation-mode-font-lock-keywords)

(define-obsolete-variable-alias 'one-drone-directory
  'one-drones-directory "One 3.2.0")

(defvar pre-user-emacs-directory nil)
(defvar one-drones-directory (concat
                              (or pre-user-emacs-directory user-emacs-directory)
                              "profiles"
                              (if (member system-type '(windows-nt ms-dos)) "\\" "/"))
  "Directory beneath which drone submodules are placed.
If you need to change this, then do so before loading `one'.")

(defconst one-user-emacs-directory
  (file-name-directory (directory-file-name one-drones-directory))
  "Directory beneath which additional per-user Emacs-specific files are placed.

The value of this variable is usually the same as that of
`user-emacs-directory', except when Emacs is started with
`emacs -q -l /path/to/init.el'.")

(defconst one-top-level-directory
  (or (ignore-errors
        (let ((default-directory one-user-emacs-directory))
          (file-name-as-directory
           (car (process-lines "git" "rev-parse" "--show-toplevel")))))
      one-user-emacs-directory)
  "The top-level of repository containing `one-user-emacs-directory'.")

(defconst one-gitmodules-file
  (expand-file-name ".gitmodules" one-top-level-directory)
  "The \".gitmodules\" file of the drone repository.")

;;; Variables

(defvar one-emacs-arguments '("-Q")
  "Arguments used when calling an inferior Emacs instance.
Set this in \"~/.emacs.d/etc/one/config.el\" and also set
`EMACS_ARGUMENTS' in \"~/.emacs.d/etc/one/config.mk\" to
the same value")

(defvar one-byte-compile-recursively nil
  "Whether to compile recursively.

Unfortunately there are many packages that put random crap
into subdirectories.  Instead of this variable you should set
`submodule.<drone>.recursive-byte-compile' for each DRONE that
needs it.")

(defvar one-build-shell-command nil
  "Optional command used to run shell command build steps.
This variable is documented in the manual (which see).")

(defvar one-rewrite-urls-alist nil
  "An alist used to optionally rewrite certain URLs.
Each element has the form (ORIG . BASE).  Each URL that starts
with ORIG is rewritten to start with BASE instead.  See info
node `(one)Using https URLs'.")

;;; Utilities

(defun one-worktree (clone)
  "Return the top-level of the working tree of the profile named CLONE."
  (expand-file-name (file-name-as-directory clone) one-drones-directory))

(defun one-gitdir (clone)
  "Return the Git directory of the profile named CLONE.

Always return `<one-user-emacs-directory>/.git/modules/<CLONE>',
even when this repository's Git directory is actually located
inside the working tree."
  (let* ((default-directory one-top-level-directory)
         (super (ignore-errors
                  (car (process-lines "git" "rev-parse" "--git-dir")))))
    (if super
        (expand-file-name (concat super "/modules/" clone "/"))
      (error "Cannot locate super-repository"))))

(defvar one--gitmodule-cache nil)

(defun one-get (clone variable &optional all)
  "Return the value of `submodule.CLONE.VARIABLE' in `~/.emacs.d/.gitmodules'.
If optional ALL is non-nil, then return all values as a list."
  (let ((values (if one--gitmodule-cache
                    (plist-get (cdr (assoc clone one--gitmodule-cache))
                               (intern variable))
                  (ignore-errors
                    ;; If the variable has no value then the exit code is
                    ;; non-zero, but that isn't an error as far as we are
                    ;; concerned.
                    (apply #'process-lines "git" "config"
                           "--file" one-gitmodules-file
                           `(,@(and all (list "--get-all"))
                             ,(concat "submodule." clone "." variable)))))))
    (if all values (car values))))

(defun one-get-all (clone variable)
  "Return all values of `submodule.CLONE.VARIABLE' in `~/.emacs.d/.gitmodules'.
Return the values as a list."
  (one-get clone variable t))

(defun one-load-path (clone)
  "Return the `load-path' for the clone named CLONE."
  (let ((repo (one-worktree clone))
        (path (one-get-all clone "load-path")))
    (if  path
        (mapcar (lambda (d) (expand-file-name d repo)) path)
      (let ((elisp (expand-file-name "elisp" repo))
            (lisp (expand-file-name "lisp" repo)))
        (list (cond ((file-exists-p elisp) elisp)
                    ((file-exists-p lisp) lisp)
                    (t repo)))))))

(defun one-info-path (clone &optional setup)
  "Return the `Info-directory-list' for the clone named CLONE.

If optional SETUP is non-nil, then return a list of directories
containing texinfo and/or info files.  Otherwise return a list of
directories containing a file named \"dir\"."
  (let ((repo (one-worktree clone))
        (path (one-get-all clone "info-path")))
    (cl-mapcan (if setup
                   (lambda (d)
                     (setq d (file-name-as-directory d))
                     (when (directory-files d t "\\.\\(texi\\(nfo\\)?\\|info\\)\\'" t)
                       (list d)))
                 (lambda (d)
                   (setq d (file-name-as-directory d))
                   (when (file-exists-p (expand-file-name "dir" d))
                     (list d))))
               (if path
                   (mapcar (lambda (d) (expand-file-name d repo)) path)
                 (list repo)))))

(defvar one--multi-value-variables
  '(build-step load-path no-byte-compile info-path)
  "List of submodule variables which can have multiple values.")

(defun one-drones* (&optional include-variables)
  "Return a list of all assimilated drones.

The returned value is a list of the names of the assimilated
drones, unless optional INCLUDE-VARIABLES is non-nil, in which
case elements of the returned list have the form (NAME . PLIST).

PLIST is a list of paired elements.  Property names are symbols
and correspond to a VARIABLE defined in the One repository's
\".gitmodules\" file as \"submodule.NAME.VARIABLE\".

Each property value is either a string or a list of strings.  If
INCLUDE-VARIABLES is `raw' then all values are lists.  Otherwise
a property value is only a list if the corresponding property
name is a member of `one--multi-value-variables'.  If a property
name isn't a member of `one--multi-value-variables' but it does
have multiple values anyway, then it is undefined with value is
included in the returned value."
  (if include-variables
      (let (alist)
        (dolist (line (and (file-exists-p one-gitmodules-file)
                           (process-lines "git" "config" "--list"
                                          "--file" one-gitmodules-file)))
          (when (string-match
                 "\\`submodule\\.\\([^.]+\\)\\.\\([^=]+\\)=\\(.+\\)\\'" line)
            (let* ((drone (match-string 1 line))
                   (prop  (intern (match-string 2 line)))
                   (value (match-string 3 line))
                   (elt   (assoc drone alist))
                   (plist (cdr elt)))
              (unless elt
                (push (setq elt (list drone)) alist))
              (setq plist
                    (plist-put plist prop
                               (if (or (eq include-variables 'raw)
                                       (memq prop one--multi-value-variables))
                                   (nconc (plist-get plist prop)
                                          (list value))
                                 value)))
              (setcdr elt plist))))
        (cl-sort alist #'string< :key #'car))
    (let* ((default-directory one-top-level-directory)
           (prefix (file-relative-name one-drones-directory))
           (offset (+ (length prefix) 50)))
      (cl-mapcan (lambda (line)
                   (and (string-equal (substring line 50 offset) prefix)
                        (list (substring line offset))))
                 (process-lines "git" "submodule--helper" "list")))))

(defun one-drones (&optional include-variables assimilating)
  (seq-filter #'(lambda (profile*) (interactive)
    (let* ((profile (car profile*))
            (path* (cl-getf (cdr profile*) 'path))
            (path (cond ((listp path*) (car path*))
                        ((stringp path*) path*)))
            (exists (file-exists-p (one-worktree profile)))
            (slash (if (member system-type '(windows-nt ms-dos)) "\\" "/")))
        (and (not (string-match-p (regexp-quote "\\") profile))
            (not (string-match-p (regexp-quote "/") profile))
            (or
              (and assimilating (not exists))
              (and exists (not assimilating)))
            (member
              (string-remove-prefix one-user-emacs-directory one-drones-directory)
              (list
                (string-remove-suffix profile path)
                (string-remove-suffix (concat profile slash "lisp") path)))))) (one-drones* t)))

(defun one-clones ()
  "Return a list of cloned packages.

The returned value includes the names of all packages that were
cloned into `one-drones-directory', including clones that have
not been assimilated yet."
  (cl-mapcan (lambda (file)
               (and (file-directory-p file)
                    (list (file-name-nondirectory file))))
             (directory-files one-drones-directory t "\\`[^.]")))

(defun one-read-profile (prompt &optional edit-url)
  "Read a profile name and URL, and return them as a list.

If the `epkg' profile is available, then read a profile name
in the minibuffer and use the URL stored in the Epkg database.

Otherwise if `epkg' is unavailable, the profile is unknown,
or when EDIT-URL is non-nil, then also read the URL in the
minibuffer.

PROMPT is used when reading the profile name.

Return a list of the form (NAME URL).  Unless the URL was
explicitly provided by the user, it may be modified according
to variable `one-rewrite-urls-alist' (which see)."
  (if (require 'epkg nil t)
      (let* ((name (completing-read prompt (epkgs 'name)
                                    nil nil nil 'ePkg-package-history))
             (profile  (epkg name))
             (url  (and profile
                        (if (or (ePkg-git-package-p profile)
                                (ePkg-github-package-p profile)
                                (ePkg-orphaned-package-p profile)
                                (ePkg-gitlab-package-p profile))
                            (eieio-oref profile 'url)
                          (eieio-oref profile 'mirror-url)))))
        (when url
          (pcase-dolist (`(,orig . ,base) one-rewrite-urls-alist)
            (when (string-prefix-p orig url)
              (setq url (concat base (substring url (length orig)))))))
        (list name
              (if (or (not url) edit-url)
                  (read-string
                   "Url: "
                   (or url
                       (and (require 'magit nil t)
                            (magit-get "remote"
                                       (magit-get-some-remote) "url"))))
                url)))
    (list (read-string prompt)
          (read-string "Url: "))))

(defun one-read-clone (prompt)
  "Read the name of a cloned profile, prompting with PROMPT."
  (require 'epkg nil t)
  (completing-read prompt (one-clones) nil t nil 'ePkg-package-history))

(defmacro one-silencio (regexp &rest body)
  "Execute the forms in BODY while silencing messages that don't match REGEXP."
  (declare (indent 1))
  (let ((msg (make-symbol "msg")))
    `(let ((,msg (symbol-function 'message)))
       (cl-letf (((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (unless (string-match-p ,regexp format-string)
                      (apply ,msg format-string args)))))
         ,@body))))

;;; Activation

(defun one-initialize ()
  "Initialize assimilated drones.

For each drone use `one-activate' to add the appropriate
directories to the `load-path' and `Info-directory-alist', and
load the autoloads file, if it exists.

If the value of a Git variable named `submodule.DRONE.disabled'
is true in \"~/.emacs.d/.gitmodules\", then the drone named DRONE
is skipped.

If Emacs is running without an interactive terminal, then first
load \"`user-emacs-directory'/etc/one/init.el\", if that exists."
  (when noninteractive
    (let ((init (expand-file-name
                 (convert-standard-filename "etc/one/init.el")
                 user-emacs-directory)))
      (when (file-exists-p init)
        (load-file init))))
  (info-initialize)
  (let ((start (current-time))
        (skipped 0)
        (initialized 0)
        (one--gitmodule-cache (one-drones 'raw)))
    (pcase-dolist (`(,drone) one--gitmodule-cache)
      (cond
       ((equal (one-get drone "disabled") "true")
        (cl-incf skipped))
       ((not (file-exists-p (one-worktree drone)))
        (cl-incf skipped))
       (t
        (cl-incf initialized)
        (one-activate drone))))
    (let* ((message (current-message))
           (inhibit (and message
                         (string-match-p
                          "\\`Recompiling .+init\\.el\\.\\.\\.\\'" message))))
      (let ((inhibit-message inhibit))
        (message "Initializing drones...done (%s drones in %.3fs%s)"
                 initialized
                 (float-time (time-subtract (current-time) start))
                 (if (> skipped 0)
                     (format ", %d skipped" skipped)
                   "")))
      (when inhibit
        (let ((message-log-max nil))
          (message "%s" message))))))

(defun one-activate (clone)
  "Activate the clone named CLONE.

Add the appropriate directories to `load-path' and
`Info-directory-list', and load the autoloads file,
if it exists."
  (interactive)
  (message "Sorry! Activating the profile \"%s\" does nothing!" clone))

;;; Construction

(defun one-batch-rebuild (&optional quick)
  "Rebuild all assimilated drones.

Drones are rebuilt in alphabetic order, except that Org is built
first.  `init.el' and `USER-REAL-LOGIN-NAME.el' are also rebuilt.

This function is to be used only with `--batch'.

When optional QUICK is non-nil, then do not build drones for
which `submodule.DRONE.build-step' is set, assuming those are the
drones that take longer to be built."
  (unless noninteractive
    (error "one-batch-rebuild is to be used only with --batch"))
  (let ((drones (one-drones)))
    (when (member "org" drones)
      ;; `org-loaddefs.el' has to exist when compiling a library
      ;; which depends on `org', else we get warnings about that
      ;; not being so, and other more confusing warnings too.
      (setq drones (cons "org" (delete "org" drones))))
    (dolist (drone drones)
      (unless (or (equal (one-get drone "disabled") "true")
                  (not (file-exists-p (one-worktree drone)))
                  (and quick (one-get-all drone "build-step")))
        (dolist (d (one-load-path drone))
          (dolist (f (directory-files
                      d t "\\(\\.elc\\|-autoloads\\.el\\|-loaddefs\\.el\\)\\'"
                      t))
            (ignore-errors (delete-file f))))))
    (dolist (drone drones)
      (message "\n--- [%s] ---\n" drone)
      (cond
       ((equal (one-get drone "disabled") "true")
        (message "Skipped (Disabled)"))
       ((not (file-exists-p (one-worktree drone)))
        (message "Skipped (Missing)"))
       ((and quick (one-get-all drone "build-step"))
        (message "Skipped (Expensive to build)"))
       (t (one-build drone)))))
  (one-batch-rebuild-init))

(defun one-batch-rebuild-init ()
  "Rebuild `init.el' and `USER-REAL-LOGIN-NAME.el'.

This function is to be used only with `--batch'."
  (unless noninteractive
    (error "one-batch-recompile-init is to be used only with --batch"))
  (one-silencio "\\`%s\\.\\.\\.\\(done\\)?" ; silence use-package
    (let ((default-directory one-user-emacs-directory))
      (dolist (file (or command-line-args-left
                        (list "init.el"
                              (concat (user-real-login-name) ".el"))))
        (when (file-exists-p file)
          (message "\n--- [%s] ---\n" file)
          (load-file file)
          (byte-recompile-file (expand-file-name file) t 0))))))

(defun one-build (clone &optional activate)
  "Build the clone named CLONE.
Interactively, or when optional ACTIVATE is non-nil,
then also activate the clone using `one-activate'."
  (interactive (list (one-read-clone "Build drone: ") t))
  ;; (if noninteractive
  ;;     (one--build-noninteractive clone)
  ;;   (one--build-interactive clone))
  (one--build-noninteractive clone)
  (when activate
    (one-activate clone)))

(defun one--build-noninteractive (clone &optional one)
  (let ((default-directory (one-worktree clone))
        (build-cmd (if (functionp one-build-shell-command)
                       (funcall one-build-shell-command clone)
                     one-build-shell-command))
        (build (one-get-all clone "build-step")))
    (if  build
        (dolist (cmd build)
          (message "  Running `%s'..." cmd)
          (cond ((string-match-p "\\`(" cmd)
                 (eval (read cmd)))
                (build-cmd
                 (when (or (stringp build-cmd)
                           (setq build-cmd (funcall build-cmd clone cmd)))
                   (require 'format-spec)
                   (shell-command
                    (format-spec build-cmd
                                 `((?s . ,cmd)
                                   (?S . ,(shell-quote-argument cmd)))))))
                (t
                 (shell-command cmd)))
          (message "  Running `%s'...done" cmd)))))

(defun one--build-interactive (clone)
  (save-some-buffers
   nil (let ((top default-directory))
         (lambda ()
           (let ((file (buffer-file-name)))
             (and file
                  (string-match-p emacs-lisp-file-regexp file)
                  (file-in-directory-p file top))))))
  (let ((buffer (get-buffer-create "*One Build*"))
        (config (expand-file-name
                 (convert-standard-filename "etc/one/config.el")
                 user-emacs-directory))
        (process-connection-type nil))
    (switch-to-buffer buffer)
    (with-current-buffer buffer
      (setq default-directory one-user-emacs-directory)
      (one-build-mode)
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (when (file-exists-p config)
          (insert (format "\n(%s) Loading %s\n\n"
                          (format-time-string "%H:%M:%S")
                          config))
          (load-file config))
        (insert (format "\n(%s) Building %s\n\n"
                        (format-time-string "%H:%M:%S")
                        clone))))
    (set-process-filter
     (apply #'start-process
            (format "emacs ... --eval (one-build %S)" clone)
            buffer
            (expand-file-name invocation-name invocation-directory)
            `("--batch" ,@one-emacs-arguments
              "-L" ,(file-name-directory (locate-library "one"))
              "--eval" ,(if (featurep 'one-elpa)
                            (format "(progn
  (setq user-emacs-directory %S)
  (require 'package)
  (package-initialize 'no-activate)
  (package-activate 'one)
  (require 'one-elpa)
  (one-elpa-initialize)
  (setq one-build-shell-command (quote %S))
  (one-build %S))" user-emacs-directory one-build-shell-command clone)
                          (format "(progn
  (require 'one)
  (one-initialize)
  (setq one-build-shell-command (quote %S))
  (one-build %S))" one-build-shell-command clone))))
     'one-build--process-filter)))

(defun one-build--process-filter (process string)
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((moving (= (point) (process-mark process))))
        (save-excursion
          (goto-char (process-mark process))
          (let ((inhibit-read-only t))
            (insert string))
          (set-marker (process-mark process) (point)))
        (if moving (goto-char (process-mark process)))))))

(defvar one-build-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-q" 'bury-buffer)
    map)
  "Keymap for `one-build-mode'.")

(defvar one-build-mode-lighter "One-Build")

(define-derived-mode one-build-mode compilation-mode
  'one-build-mode-lighter
  "Mode for the \"*One Build*\" buffer."
  (setq mode-line-process
        '((:propertize ":%s" face compilation-mode-line-run)
          compilation-mode-line-errors))
  (setq font-lock-defaults '(one-build-mode-font-lock-keywords t)))

(defun one-build-mode-font-lock-keywords ()
  (append '((compilation--ensure-parse))
          (remove '(" --?o\\(?:utfile\\|utput\\)?[= ]\\(\\S +\\)" . 1)
                  compilation-mode-font-lock-keywords)))

(defconst one-autoload-format "\
;;;\
 %s --- automatically extracted autoloads
;;
;;;\
 Code:
\(add-to-list 'load-path (directory-file-name \
\(or (file-name-directory #$) (car load-path))))
\
;; Local Variables:
;; version-control: never
;; no-byte-compile: t
;; no-update-autoloads: t
;; End:
;;;\
 %s ends here\n")

(defun one-update-autoloads (clone &optional path)
  "Update autoload files for the clone named CLONE in the directories in PATH."
  (setq path (one--expand-load-path clone path))
  (let ((autoload-excludes
         (nconc (mapcar #'expand-file-name
                        (one-get-all clone "no-byte-compile"))
                (cl-mapcan
                 (lambda (dir)
                   (list (expand-file-name (concat clone "-pkg.el") dir)
                         (expand-file-name (concat clone "-test.el") dir)
                         (expand-file-name (concat clone "-tests.el") dir)))
                 path)
                autoload-excludes))
        (generated-autoload-file
         (expand-file-name (format "%s-autoloads.el" clone) (car path))))
    (message " Creating %s..." generated-autoload-file)
    (when (file-exists-p generated-autoload-file)
      (delete-file generated-autoload-file t))
    (let* ((backup-inhibited t)
           (version-control 'never)
           (noninteractive t)
           (filename (file-name-nondirectory generated-autoload-file)))
      (write-region (format one-autoload-format filename filename)
                    nil generated-autoload-file nil 'silent)
      (cl-letf (((symbol-function 'progress-reporter-do-update) (lambda (&rest _)))
                ((symbol-function 'progress-reporter-done) (lambda (_))))
        (cond ((fboundp 'make-directory-autoloads)   ; >= 28
               (make-directory-autoloads path generated-autoload-file))
              ((fboundp 'update-directory-autoloads) ; <= 27
               (apply 'update-directory-autoloads path)))))
    (when-let ((buf (find-buffer-visiting generated-autoload-file)))
      (kill-buffer buf))))

(defun one-byte-compile (clone &optional path)
  "Compile libraries for the clone named CLONE in the directories in PATH."
  (let ((dirs (one--expand-load-path clone path))
        (exclude (one-get-all clone "no-byte-compile"))
        (topdir (one-worktree clone))
        (default-directory     one-user-emacs-directory)
        (byte-compile-root-dir one-user-emacs-directory)
        (skip-count 0)
        (fail-count 0)
        (file-count 0)
        (dir-count  0)
        dir last-dir)
    (displaying-byte-compile-warnings
     (while (setq dir (pop dirs))
       (dolist (file (directory-files dir t))
         (let ((file-relative (file-relative-name file topdir))
               (name (file-name-nondirectory file)))
           (if (file-directory-p file)
               (when (and (if-let ((v (one-get
                                       clone "recursive-byte-compile")))
                              (member v '("yes" "on" "true" "1"))
                            one-byte-compile-recursively)
                          (not (file-symlink-p file))
                          (not (string-prefix-p "." name))
                          (not (member name '("RCS" "CVS"))))
                 (if (or (file-exists-p (expand-file-name ".nosearch" file))
                         (member file-relative exclude))
                     (message " Skipping %s...skipped" file)
                   (setq dirs (nconc dirs (list file)))))
             (when (and (file-regular-p  file)
                        (file-readable-p file)
                        (string-match-p emacs-lisp-file-regexp name)
                        (not (auto-save-file-name-p file))
                        (not (string-match-p "\\`\\." name))
                        (not (string-match-p "-autoloads.el\\'" name))
                        (not (string-equal dir-locals-file name)))
               (cl-incf
                (if (or (string-match-p "-pkg.el\\'" name)
                        (string-match-p "-tests?.el\\'" name)
                        (member file-relative exclude))
                    (progn (message " Skipping %s...skipped" file)
                           skip-count)
                  (unless byte-compile-verbose
                    (message "Compiling %s..." file))
                  (pcase (byte-compile-file file)
                    ('no-byte-compile
                     (message "Compiling %s...skipped" file)
                     skip-count)
                    ('t file-count)
                    (_  fail-count))))
               (unless (equal dir last-dir)
                 (setq last-dir dir)
                 (cl-incf dir-count))))))))
    (message "Done (Total of %d file%s compiled%s%s%s)"
             file-count (if (= file-count 1) "" "s")
             (if (> fail-count 0) (format ", %d failed"  fail-count) "")
             (if (> skip-count 0) (format ", %d skipped" skip-count) "")
             (if (> dir-count  1) (format " in %d directories" dir-count) ""))))

(defun one-makeinfo (clone)
  "Generate Info manuals and the Info index for the clone named CLONE."
  (dolist (default-directory (one-info-path clone t))
    (let ((exclude (one-get-all clone "no-makeinfo")))
      (dolist (texi (directory-files default-directory nil "\\.texi\\(nfo\\)?\\'"))
        (let ((info (concat (file-name-sans-extension texi) ".info")))
          (when (and (not (member texi exclude))
                     (or (not (file-exists-p info))
                         (= (process-file "git" nil nil nil
                                          "ls-files" "--error-unmatch" info)
                            1)))
            (let ((cmd (format "makeinfo --no-split %s -o %s" texi info)))
              (message "  Running `%s'..." cmd)
              (one-silencio "\\`(Shell command succeeded with %s)\\'"
                (shell-command cmd))
              (message "  Running `%s'...done" cmd))))))
    (dolist (info (directory-files default-directory nil "\\.info\\'"))
      (let ((cmd (format "install-info %s --dir=dir" info)))
        (message "  Running `%s'..." cmd)
        (one-silencio "\\`(Shell command succeeded with %s)\\'"
          (shell-command cmd))
        (message "  Running `%s'...done" cmd)))))

;;; Assimilation

;; (defun one-assimilate (profile url &optional partially)
;;   "Assimilate the profile named PROFILE from URL.

;; If `epkg' is available, then only read the name of the profile
;; in the minibuffer and use the url stored in the Epkg database.
;; If `epkg' is unavailable, the profile is not in the database, or
;; with a prefix argument, then also read the url in the minibuffer.

;; With a negative prefix argument only add the submodule but don't
;; build and activate the drone."
;;   (interactive
;;    (nconc (one-read-profile "Assimilate profile: " current-prefix-arg)
;;           (list (< (prefix-numeric-value current-prefix-arg) 0))))
;;   (one--maybe-confirm-unsafe-action "assimilate" profile url)
;;   (message "Assimilating %s..." profile)
;;   (let ((default-directory one-top-level-directory))
;;     (one--maybe-reuse-gitdir profile)
;;     (one--call-git profile
;;                   "submodule"
;;                   "add"
;;                   "--name"
;;                   (concat "profile" (if (member system-type '(windows-nt ms-dos)) "\\" "/"))
;;                   profile
;;                   url
;;                   (file-relative-name (one-worktree profile)))
;;     (one--sort-submodule-sections ".gitmodules")
;;     (one--call-git profile "config" "--add" "-f" ".gitmodules" (concat "submodule." profile ".profile") "true")
;;     (one--call-git profile "config" "--add" "-f" ".gitmodules" (concat "submodule." profile ".s8472") "true")
;;     (one--call-git profile "add" ".gitmodules")
;;     (one--maybe-absorb-gitdir profile))
;;   (unless partially (one-build profile))
;;   (one--refresh-magit)
;;   (message "Assimilating %s...done" profile))

(defun one-assimilate (profile url &optional partially)
  "Assimilate the profile named PROFILE from URL.

If `epkg' is available, then only read the name of the profile
in the minibuffer and use the url stored in the Epkg database.
If `epkg' is unavailable, the profile is not in the database, or
with a prefix argument, then also read the url in the minibuffer.

With a negative prefix argument only add the submodule but don't
build and activate the drone."
  (interactive
   (nconc (one-read-profile "Assimilate profile: " current-prefix-arg)
          (list (< (prefix-numeric-value current-prefix-arg) 0))))
  (one--maybe-confirm-unsafe-action "assimilate" profile url)
  (message "Assimilating %s..." profile)
  (unless (equal (one-get profile "s8472") "true")
      (one--maybe-reuse-gitdir profile)
      (one--call-git
        profile
        "-C" one-top-level-directory
        "submodule"
        "add"
        "-f"
        "--depth" "1"
        "--name" profile
        url
        (or
          (one-get profile "path")
          (concat
            (string-remove-prefix one-user-emacs-directory one-drones-directory)
            (if (member system-type '(windows-nt ms-dos)) "\\" "/")
            profile)))
      (one--sort-submodule-sections ".gitmodules")
      (one--call-git profile "add" ".gitmodules")
      (one--maybe-absorb-gitdir profile))
  (unless partially (one-build profile))
  (one--refresh-magit)
  (message "Assimilating %s...done" profile))

(defun one-clone (profile url)
  "Clone the profile named PROFILE from URL, without assimilating it.

If `epkg' is available, then only read the name of the profile
in the minibuffer and use the url stored in the Epkg database.
If `epkg' is unavailable, the profile is not in the database, or
with a prefix argument, then also read the url in the minibuffer."
  (interactive (one-read-profile "Clone profile: " current-prefix-arg))
  (one--maybe-confirm-unsafe-action "clone" profile url)
  (message "Cloning %s..." profile)
  (let ((gitdir (one-gitdir profile))
        (topdir (one-worktree profile)))
    (when (file-exists-p topdir)
      (user-error "%s already exists" topdir))
    (let ((default-directory one-top-level-directory))
      (one--maybe-reuse-gitdir profile)
      (unless (file-exists-p topdir)
        (one--call-git profile "clone"
                        (concat "--separate-git-dir="
                                ;; Git fails if this ends with slash.
                                (directory-file-name gitdir))
                        url (file-relative-name topdir)))
      (one--link-gitdir profile))
    (one--refresh-magit)
    (message "Cloning %s...done" profile)))

(defun one-remove (clone)
  "Remove the cloned or assimilated profile named CLONE.

Remove the working tree from `one-drones-directory', regardless
of whether that repository belongs to an assimilated profile or a
profile that has only been cloned for review using `one-clone'.
The Git directory is not removed."
  (interactive (list (one-read-clone "Uninstall clone: ")))
  (message "Removing %s..." clone)
  (let ((topdir (one-worktree clone)))
    (let ((default-directory topdir))
      (when (or (not (one--git-success "diff" "--quiet" "--cached"))
                (not (one--git-success "diff" "--quiet")))
        (user-error "%s contains uncommitted changes" topdir))
      (one--maybe-absorb-gitdir clone))
    (if (member clone (one-drones))
        (let ((default-directory one-top-level-directory))
          (one--call-git nil "rm" "--force" (file-relative-name topdir)))
      (delete-directory topdir t t)))
  (one--refresh-magit)
  (message "Removing %s...done" clone))

;;; Convenience

(with-eval-after-load 'git-commit
  (define-key git-commit-mode-map "\C-c\C-b" 'one-insert-update-message))

(defun one-insert-update-message ()
  "Insert information about drones that are changed in the index.
Formatting is according to the commit message conventions."
  (interactive)
  (when-let ((alist (one--drone-states)))
    (let ((width (apply #'max (mapcar (lambda (e) (length (car e))) alist)))
          (align (cl-member-if (pcase-lambda (`(,_ ,_ ,version))
                                 (and version
                                      (string-match-p "\\`v[0-9]" version)))
                               alist)))
      (when (> (length alist) 1)
        (let ((a 0) (m 0) (d 0))
          (pcase-dolist (`(,_ ,state ,_) alist)
            (pcase state
              ("A" (cl-incf a))
              ("M" (cl-incf m))
              ("D" (cl-incf d))))
          (insert (format "%s %-s drones\n\n"
                          (pcase (list a m d)
                            (`(,_ 0 0) "Assimilate")
                            (`(0 ,_ 0) "Update")
                            (`(0 0 ,_) "Remove")
                            (_         "CHANGE"))
                          (length alist)))))
      (pcase-dolist (`(,drone ,state ,version) alist)
        (insert
         (format
          (pcase state
            ("A" (format "Assimilate %%-%is %%s%%s\n" width))
            ("M" (format "Update %%-%is to %%s%%s\n" width))
            ("D" "Remove %s\n"))
          drone
          (if (and align version
                   (string-match-p "\\`\\([0-9]\\|[0-9a-f]\\{7\\}\\)" version))
              " "
            "")
          version))))))

(defun one--drone-states ()
  (let ((default-directory one-user-emacs-directory))
    (mapcar
     (lambda (line)
       (pcase-let ((`(,state ,module) (split-string line "\t")))
         (list (file-name-nondirectory module)
               state
               (and (member state '("A" "M"))
                    (let ((default-directory (expand-file-name module)))
                      (if (file-directory-p default-directory)
                          (car (process-lines
                                "git" "describe" "--tags" "--always"))
                        "REMOVED"))))))
     (process-lines "git" "diff-index" "--name-status" "--cached" "HEAD"
                    "--" (file-relative-name one-drones-directory)))))

;;; Internal Utilities

(defun one--maybe-absorb-gitdir (profile)
  (let* ((ver (nth 2 (split-string (car (process-lines "git" "version")) " ")))
         (ver (and (string-match "\\`[0-9]+\\(\\.[0-9]+\\)*" ver)
                   (match-string 0 ver))))
    (if (version< ver "2.12.0")
        (let ((gitdir (one-gitdir profile))
              (topdir (one-worktree profile)))
          (unless (equal (let ((default-directory topdir))
                           (car (process-lines "git" "rev-parse" "--git-dir")))
                         (directory-file-name gitdir))
            (rename-file (expand-file-name ".git" topdir) gitdir)
            (one--link-gitdir profile)
            (let ((default-directory gitdir))
              (one--call-git profile "config" "core.worktree"
                              (concat "../../../profiles/" profile)))))
      (one--call-git profile "submodule" "absorbgitdirs" "--" (one-worktree profile)))))

;; (defun one--maybe-reuse-gitdir (profile)
;;   (let ((gitdir (one-gitdir profile))
;;         (topdir (one-worktree profile)))
;;     (when (and (file-exists-p gitdir)
;;                (not (file-exists-p topdir)))
;;       (pcase (read-char-choice
;;               (concat
;;                gitdir " already exists.\n"
;;                "Type [r] to reuse the existing gitdir and create the worktree\n"
;;                "     [d] to delete the old gitdir and clone again\n"
;;                "   [C-g] to abort ")
;;               '(?r ?d))
;;         (?r (one--restore-worktree profile))
;;         (?d (delete-directory gitdir t t))))))

(defalias #'one--maybe-reuse-gitdir #'ignore)

(defun one--restore-worktree (profile)
  (let ((topdir (one-worktree profile)))
    (make-directory topdir t)
    (one--link-gitdir profile)
    (let ((default-directory topdir))
      (one--call-git profile "reset" "--hard" "HEAD"))))

(defun one--link-gitdir (profile)
  (let ((gitdir (one-gitdir profile))
        (topdir (one-worktree profile)))
    (with-temp-file (expand-file-name ".git" topdir)
      (insert "gitdir: " (file-relative-name gitdir topdir) "\n"))))

(defun one--call-git (profile &rest args)
  (let ((process-connection-type nil)
        (buffer (generate-new-buffer
                 (concat " *One Git" (and profile (concat " " profile)) "*"))))
    (if (eq (apply #'call-process "git" nil buffer nil args) 0)
        (kill-buffer buffer)
      (with-current-buffer buffer
        (special-mode))
      (pop-to-buffer buffer)
      (error "One Git: %s | %s:\n\n%s" profile args (buffer-string)))))

(defun one--git-success (&rest args)
  (= (apply #'process-file "git" nil nil nil args) 0))

(defun one--refresh-magit ()
  (when (and (derived-mode-p 'magit-mode)
             (fboundp 'magit-refresh))
    (magit-refresh)))

(defun one--expand-load-path (clone path)
  (let ((default-directory (one-worktree clone)))
    (mapcar (lambda (p)
              (file-name-as-directory (expand-file-name p)))
            (or path (one-load-path clone)))))

(defun one--sort-submodule-sections (file)
  "Sort submodule sections in the current buffer.
Non-interactively operate in FILE instead."
  (interactive (list buffer-file-name))
  (with-current-buffer (or (find-buffer-visiting file)
                           (find-file-noselect file))
    (revert-buffer t t)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\[submodule" nil t)
        (let ((end (or (and (save-excursion (re-search-forward "^##+ ." nil t))
                            (match-beginning 0))
                       (point-max))))
          (sort-regexp-fields
           nil
           "^\\(?:#.*\n\\)*\\[submodule \"\\([^\"]+\\)\"].*\\(?:[^[].*\n\\)+"
           "\\1" (line-beginning-position) end)
          (goto-char end))))
    (save-buffer)))

;; (defun one--maybe-confirm-unsafe-action (action profile url)
;;   (require 'epkg nil t)
;;   (let* ((profile (and (fboundp 'epkg)
;;                    (epkg profile)))
;;          (ask (cond ((and profile
;;                           (fboundp 'ePkg-wiki-profile-p)
;;                           (ePkg-wiki-profile-p profile)) "\
;; This profile is from the Emacswiki.  Anyone could trivially \
;; inject malicious code.  Do you really want to %s it? ")
;;                     ((or (and profile
;;                               (fboundp 'ePkg-orphaned-profile-p)
;;                               (ePkg-orphaned-profile-p profile))
;;                          (string-match-p "emacsorphanage" url)) "\
;; This profile is from the Emacsorphanage, which might import it \
;; over an insecure connection.  Do you really want to %s it? ")
;;                     ((or (and profile
;;                               (fboundp 'ePkg-shelved-profile-p)
;;                               (ePkg-shelved-profile-p profile))
;;                          (string-match-p "emacsattic" url)) "\
;; This profile is from the Emacsattic, which might have imported it \
;; over an insecure connection.  Do you really want to %s it? ")
;;                     ((or (string-prefix-p "git://" url)
;;                          (string-prefix-p "http://" url)) "\
;; This profile is being fetched over an insecure connection. \
;; Do you really want to %s it? "))))
;;     (when (and ask (not (yes-or-no-p (format ask action))))
;;       (user-error "Abort"))))

(defalias #'one--maybe-confirm-unsafe-action #'ignore)

;;; _
(provide 'one)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; one.el ends here
