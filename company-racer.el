;;; company-racer.el --- Company integration for racer -*- lexical-binding: t -*-

;; Copyright (C) 2015 Mario Rodas <marsam@users.noreply.github.com>

;; Author: Mario Rodas <marsam@users.noreply.github.com>
;; URL: https://github.com/emacs-pe/company-racer
;; Keywords: convenience
;; Version: 0.1
;; Package-Requires: ((emacs "24") (cl-lib "0.5") (company "0.8.0") (deferred "0.3.1") (rust-mode "0.2.0"))

;; This file is NOT part of GNU Emacs.

;;; License:

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
;; [![Travis build status](https://travis-ci.org/emacs-pe/company-racer.svg?branch=master)](https://travis-ci.org/emacs-pe/company-racer)

;; A company backend for [racer][].
;;
;; Setup:
;;
;; Install and configure [racer][]. And add to your `init.el':
;;
;;     (require 'company-racer)
;;
;;     (with-eval-after-load 'company
;;       (add-to-list 'company-backends 'company-racer))
;;
;; Check https://github.com/company-mode/company-mode for details.
;;
;; Troubleshoting:
;;
;; + [racer][] requires to set the environment variable with
;;   `RUST_SRC_PATH' and needs to be an absolute path:
;;
;;       (unless (getenv "RUST_SRC_PATH")
;;         (setenv "RUST_SRC_PATH" (expand-file-name "~/path/to/rust/src")))

;; TODO:
;;
;; + [ ] Add support for find-definition (maybe not in this package.)
;;
;; [racer]: https://github.com/phildawes/racer
;; [rust-lang]: http://www.rust-lang.org/

;;; Code:
(eval-when-compile (require 'cl-lib))

(require 'company)
(require 'thingatpt)
(require 'deferred)
(require 'rust-mode)

(defgroup company-racer nil
  "Company integration for rust-mode"
  :group 'company)

(defcustom company-racer-executable "racer"
  "Path to the racer binary."
  :type 'file
  :group 'company-racer)

(defcustom company-racer-rust-src (getenv "RUST_SRC_PATH")
  "Path to rust lang sources, needs to be an absolute path.

If non nil overwrites the value of the environment variable 'RUST_SRC_PATH'."
  :type 'directory
  :group 'company-racer)

(defcustom company-racer-skip-comment-completion t
  "Skip completion prompt when the point is at a comment."
  :type 'boolean
  :group 'company-racer)

(defcustom company-racer-skip-string-completion t
  "Skip completion prompt when the point is at a string."
  :type 'boolean
  :group 'company-racer)

;; TODO: is there a better way to do this?
(defvar company-racer-temp-file nil)

(defvar company-racer-syntax-table
  (let ((table (make-syntax-table rust-mode-syntax-table)))
    (modify-syntax-entry ?: "_" table)
    table))

(defun company-racer-prefix ()
  "Get a prefix from current position."
  (ignore-errors
    (with-syntax-table company-racer-syntax-table
      (and (eq major-mode 'rust-mode)
           (let ((face (get-text-property (point) 'face))
                 (bounds (or (bounds-of-thing-at-point 'symbol)
                             (and (eq (char-before) ?.)
                                  (cons (1- (point)) (point)))))
                 (thing 'stop))
             (and bounds
                  (if (and (eq face 'font-lock-comment-face)
                           company-racer-skip-comment-completion)
                      nil t)
                  (if (and (eq face 'font-lock-string-face)
                           company-racer-skip-string-completion)
                      nil t)
                  (setq thing (buffer-substring-no-properties (car bounds)
                                                              (cdr bounds))))
             thing)))))

(defun company-racer-complete-at-point ()
  "Call racer complete for PREFIX, return a deferred object."
  (let ((process-environment (if company-racer-rust-src
                                 (append (list
                                          (format "RUST_SRC_PATH=%s" (expand-file-name company-racer-rust-src)))
                                         process-environment)
                               process-environment)))
    (let ((line (number-to-string (count-lines (point-min) (min (1+ (point)) (point-max)))))
          (column (number-to-string (- (point) (line-beginning-position)))))
      (write-region nil nil company-racer-temp-file nil 0)
      (deferred:process company-racer-executable "complete" line column company-racer-temp-file))))

;; TODO: Use the rest of information
(defun company-racer-parse-candidate (prefix line)
  "Return a completion candidate for PREFIX and LINE."
  (let* ((match (and (string-prefix-p "MATCH" line) (cadr (split-string line " "))))
         (values (and match (split-string match ","))))
    (and values
         (cl-multiple-value-bind (matchstr _ _ _ matchtype contextstr) values
           ;; FIXME: Add the prefix because currently racer doesn't
           ;;        add the prefix when completing modules, and fails
           ;;        when there are characters after "::"
           (and (string-match-p "::" prefix)
                (setq matchstr (concat prefix matchstr)))
           (put-text-property 0 1 :matchtype matchtype matchstr)
           (put-text-property 0 1 :contextstr contextstr matchstr)
           matchstr))))

(defun company-racer-candidates (prefix callback)
  "Return candidates for PREFIX with CALLBACK."
  (deferred:nextc
    (company-racer-complete-at-point)
    (lambda (output)
      (let ((candidates (cl-loop for line in (split-string output "\n")
                                 for candidate = (company-racer-parse-candidate prefix line)
                                 unless (null candidate)
                                 collect candidate)))
        (and candidates
             (funcall callback candidates))))))

(defun company-racer-meta (candidate)
  "Show type info for a CANDIDATE."
  (get-text-property 0 :matchtype candidate))

;;;###autoload
(defun company-racer (command &optional arg &rest ignored)
  "`company-mode' completion back-end for racer.
Provide completion info according to COMMAND and ARG.  IGNORED, not used."
  (interactive (list 'interactive))
  (cl-case command
    (init (and (null company-racer-temp-file)
               (setq company-racer-temp-file (make-temp-file "company-racer"))))
    (interactive (company-begin-backend 'company-racer))
    (prefix (and (derived-mode-p 'rust-mode)
                 (company-racer-prefix)))
    (candidates (cons :async
                      (lambda (cb) (company-racer-candidates arg cb))))
    (meta (company-racer-meta arg))
    (doc-buffer nil)
    (duplicates t)
    (location nil)))

(provide 'company-racer)

;;; company-racer.el ends here
