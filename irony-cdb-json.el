;;; irony-cdb-json.el --- JSON Compilation Database support for irony

;; Copyright (C) 2014  Guillaume Papin

;; Author: Guillaume Papin <guillaume.papin@epitech.eu>
;; Keywords: c, convenience, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; JSON Compilation Database support for Irony, see
;; http://clang.llvm.org/docs/JSONCompilationDatabase.html.
;;

;;; Code:

(require 'irony-cdb)

(require 'cl-lib)

(require 'json)

;;;###autoload
(defun irony-cdb-json (command &rest args)
  (cl-case command
    (get-compile-options (irony-cdb-json--get-compile-options))))

(defun irony-cdb-json--get-compile-options ()
  (irony--awhen (irony-cdb-json--locate-db)
    (let ((db (irony-cdb-json--load-db it)))
      (irony--aif (irony-cdb-json--exact-flags db)
          it
        (let ((dir-cdb (irony-cdb-json--compute-directory-cdb db)))
          (irony-cdb-json--guess-flags dir-cdb))))))

(defun irony-cdb-json--locate-db ()
  (when buffer-file-name
    (irony--awhen (locate-dominating-file buffer-file-name
                                          "compile_commands.json")
      (concat (file-name-as-directory it) "compile_commands.json"))))

(defun irony-cdb-json--load-db (json-file)
  (delq nil (mapcar #'irony-cdb-json--transform-compile-command
                    ;; JSON read may throw
                    (json-read-file json-file))))

(defun irony-cdb-json--exact-flags (file-cdb)
  (mapcar #'(lambda (e)
              (cons (nth 1 e) (nth 2 e)))
          (irony--assoc-all buffer-file-name file-cdb)))

(defun irony-cdb-json--guess-flags (dir-cdb)
  (cl-loop for e in dir-cdb
           with buf-path = (or buffer-file-name default-directory)
           with found = nil
           for dir = (car e)
           ;; keep the closest directory
           if (and (string-prefix-p dir buf-path)
                   (> (length dir) (length found)))
           do (setq found e)
           finally return (list (cons (nth 1 e) (nth 2 e)))))

(defsubst irony-cdb-json--compile-command-directory (compile-command)
  (cdr (assq 'directory compile-command)))

(defsubst irony-cdb-json--compile-command-file (compile-command)
  (cdr (assq 'file compile-command)))

(defun irony-cdb-json--compile-command-options (compile-command)
  "Return the compile options of COMPILE-COMMAND as a list."
  (cdr                                  ;remove compiler from returned value
   (irony--split-command-line (cdr (assq 'command compile-command)))))

(defun irony-cdb-json--adjust-compile-options (compile-options file default-dir)
  "Adjust COMPILE-OPTIONS to only use options useful for parsing.

COMPILE-OPTIONS is modified by side effects but the returned list
should be used since elements can change at the head.

Removes the input file, the output file, ...

Relative paths are relative to DEFAULT-DIR."
  ;; compute the absolute path for FILE only once
  (setq file (expand-file-name file default-dir))
  (let* ((head (cons 'nah compile-options))
         (it head)
         opt)
    (while (setq opt (cadr it))
      (cond
       ;; end of options, skip all positional arguments (source files)
       ((string= opt "--")
        (setcdr it nil))
       ;; strip -c
       ((string= "-c" opt)
        (setcdr it (nthcdr 2 it)))
       ;; strip -o <output-file> and -o<output-file>
       ((string-prefix-p "-o" opt)
        (if (string= opt "-o")
            (setcdr it (nthcdr 3 it))
          (setcdr it (nthcdr 2 it))))
       ;; skip input file
       ((string= file (expand-file-name opt default-dir))
        (setcdr it (nthcdr 2 it)))
       (t
        ;; if head of cdr hasn't been skipped, iterate, otherwise check if the
        ;; new cdr need skipping
        (setq it (cdr it)))))
    (cdr head)))

(defun irony-cdb-json--transform-compile-command (compile-command)
  "Transform a compile command in the JSON compilation database
into a friendlier format.

The returned value is a list composed of the following elements:
0. The absolute path to the file.
1. The compile options.
2. The invocation directory. Relative paths in the compile
   options elements are relative to this directory.

Return nil if the compile command is invalid or the compile
options are empty."
  (let* ((directory (irony-cdb-json--compile-command-directory compile-command))
         (path (expand-file-name
                (irony-cdb-json--compile-command-file compile-command) directory))
         (options (irony-cdb-json--compile-command-options compile-command)))
    (when (and path directory options)
      (list path
            (irony-cdb-json--adjust-compile-options options path directory)
            directory))))

(defun irony-cdb-json--compute-directory-cdb (file-cdb)
  ;; collect flags by directory, e.g: for headers in source directories or
  ;; new files that are not yet present in the compilation database
  (let ((dir-cdb (irony-cdb-json--collect-compile-options-by-dir file-cdb)))
    (nconc dir-cdb
           ;; collect flags for header search paths too
           (irony-cdb-json--collect-compile-options-for-include-dirs dir-cdb))))

(defun irony-cdb-json--collect-compile-options-by-dir (file-cdb)
  "Collect the compile options per directory from a file compilation database.

The returned value similar to
`irony-cdb-json--transform-compile-command' except for the first
argument which represents a whole directory (ending with slash on
Unix, `file-name-as-directory') instead of a single file."
  (let ((dir-cdb (delete-dups
                  (mapcar #'(lambda (e)
                              (cons (file-name-directory (car e)) (cdr e)))
                          file-cdb))))
    ;; TODO: remove directories when a parent directory has the same flags, for
    ;; example, writing the following in CMake:
    ;;     add_executable(exe foo.cpp sub/bar.cpp)
    ;; will result in duplicated compile options for the subdirectory 'sub/'.
    dir-cdb))

(defun irony-cdb-json--collect-compile-options-for-include-dirs (dir-cdb)
  "Guess the compile options to use for directories in the search path.

The returned value is in the same format as the input value, see
`irony-cdb-json--collect-compile-options-for-include-dirs'."
  (let ((include-dirs (delete-dups (mapcar 'car dir-cdb)))
        out)
    (dolist (e dir-cdb)
      (dolist (dir (irony--extract-user-search-paths (nth 1 e) (nth 2 e)))
        (unless (member dir include-dirs)
          (setq include-dirs (cons dir include-dirs)
                out (cons (cons dir (cdr e)) out)))))
    out))

(provide 'irony-cdb-json)

;; Local Variables:
;; byte-compile-warnings: (not cl-functions)
;; End:

;;; irony-cdb-json ends here
