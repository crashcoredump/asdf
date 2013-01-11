;;;; -------------------------------------------------------------------------
;;;; Handle compatibility with multiple implementations.
;;; This file is for papering over the deficiencies and peculiarities
;;; of various Common Lisp implementations.
;;; For implementation-specific access to the system, see os.lisp instead.

(asdf/package:define-package :asdf/compatibility
  (:use :common-lisp :asdf/package)
  (:recycle :asdf/compatibility :asdf)
  #+cormanlisp
  (:export
   #:logical-pathname #:translate-logical-pathname
   #:make-broadcast-stream #:file-namestring)
  #+ecl (:export #:use-ecl-byte-compiler-p)
  #+genera (:import-from :scl #:boolean)
  #+genera (:export #:boolean #:ensure-directories-exist)
  (:export
   #:strcat #:compatfmt))
(in-package :asdf/compatibility)

#-(or abcl allegro clisp clozure cmu cormanlisp ecl gcl genera lispworks mcl mkcl sbcl scl xcl)
(error "ASDF is not supported on your implementation. Please help us port it.")

;; (declaim (optimize (speed 1) (debug 3) (safety 3))) ; DON'T: trust implementation defaults.


;;;; Early meta-level tweaks

#+(or abcl (and allegro ics) (and (or clisp cmu ecl mkcl) unicode)
      clozure lispworks (and sbcl sb-unicode) scl)
(eval-when (:load-toplevel :compile-toplevel :execute)
  (pushnew :asdf-unicode *features*))

#+allegro
(eval-when (:load-toplevel :compile-toplevel :execute)
  (setf excl::*autoload-package-name-alist*
        (remove "asdf" excl::*autoload-package-name-alist*
                :test 'equalp :key 'car)) ; need that BEFORE any mention of package ASDF as below
  (defparameter *acl-warn-save*
    (when (boundp 'excl:*warn-on-nested-reader-conditionals*)
      excl:*warn-on-nested-reader-conditionals*))
  (when (boundp 'excl:*warn-on-nested-reader-conditionals*)
    (setf excl:*warn-on-nested-reader-conditionals* nil)))

#+ecl
(eval-when (:load-toplevel :compile-toplevel :execute)
  (defun use-ecl-byte-compiler-p () (and (member :ecl-bytecmp *features*) t))
  (unless (use-ecl-byte-compiler-p) (require :cmp)))

#+gcl ;; Debian's GCL 2.7 has bugs with compiling multiple-value stuff, but can run ASDF 2.011
(eval-when (:load-toplevel :compile-toplevel :execute)
  (when (or (< system::*gcl-major-version* 2) ;; GCL 2.6 lacks output-translations and more.
            (and (= system::*gcl-major-version* 2)
                 (< system::*gcl-minor-version* 7)))
    (shadow 'type-of :asdf/compatibility)
    (pushnew 'ignorable pcl::*variable-declarations-without-argument*)
    (pushnew :gcl<2.7 *features*)))

#+mkcl
(eval-when (:load-toplevel :compile-toplevel :execute)
  (require :cmp)
  (setq clos::*redefine-class-in-place* t)) ;; Make sure we have strict ANSI class redefinition semantics


;;;; Compatibility layers

#+cormanlisp
(progn
  (deftype logical-pathname () nil)
  (defun make-broadcast-stream () *error-output*)
  (defun translate-logical-pathname (x) x)
  (defun file-namestring (p)
    (setf p (pathname p))
    (format nil "~@[~A~]~@[.~A~]" (pathname-name p) (pathname-type p))))

#+gcl<2.7
(progn ;; Doesn't support either logical-pathnames or output-translations.
  (deftype logical-pathname () nil)
  (defun type-of (x) (class-name (class-of x)))
  (defun wild-pathname-p (path) (declare (ignore path)) nil)
  (defun translate-logical-pathname (x) x)
  (defvar *compile-file-pathname* nil)
  (defun pathname-match-p (in-pathname wild-pathname)
    (declare (ignore in-wildname wild-wildname)) nil)
  (defun translate-pathname (source from-wildname to-wildname &key)
    (declare (ignore from-wildname to-wildname)) source)
  (defun %print-unreadable-object (object stream type identity thunk)
    (format stream "#<~@[~S ~]" (when type (type-of object)))
    (funcall thunk)
    (format stream "~@[ ~X~]>" (when identity (system:address object))))
  (defmacro with-compilation-unit (options &body body)
    (declare (ignore options)) `(progn ,@body))
  (defmacro print-unreadable-object ((object stream &key type identity) &body body)
    `(%print-unreadable-object ,object ,stream ,type ,identity (lambda () ,@body)))
  (defun ensure-directories-exist (path)
    (run-shell-command "mkdir -p ~S" (namestring (pathname-directory-pathname path)))))

#+genera
(unless (fboundp 'ensure-directories-exist)
  (defun ensure-directories-exist (path)
    (fs:create-directories-recursively (pathname path))))

#.(or #+mcl ;; the #$ doesn't work on other lisps, even protected by #+mcl
      (read-from-string
       "(eval-when (:compile-toplevel :load-toplevel :execute)
          (ccl:define-entry-point (_getenv \"getenv\") ((name :string)) :string)
          (ccl:define-entry-point (_system \"system\") ((name :string)) :int)
          ;; Note: ASDF may expect user-homedir-pathname to provide
          ;; the pathname of the current user's home directory, whereas
          ;; MCL by default provides the directory from which MCL was started.
          ;; See http://code.google.com/p/mcl/wiki/Portability
          (defun current-user-homedir-pathname ()
            (ccl::findfolder #$kuserdomain #$kCurrentUserFolderType))
          (defun probe-posix (posix-namestring)
            \"If a file exists for the posix namestring, return the pathname\"
            (ccl::with-cstrs ((cpath posix-namestring))
              (ccl::rlet ((is-dir :boolean)
                          (fsref :fsref))
                (when (eq #$noerr (#_fspathmakeref cpath fsref is-dir))
                  (ccl::%path-from-fsref fsref is-dir))))))"))


;;;; compatfmt: avoid fancy format directives when unsupported
;; Confirm (?) has to be inside an eval-when to make Lispworks happy

(eval-when (:load-toplevel :compile-toplevel :execute)
  (defun strcat (&rest strings)
    (apply 'concatenate 'string strings)))

(defmacro compatfmt (format)
  #+(or gcl genera)
  (loop :for (unsupported . replacement)
        :in (append
             '(("~3i~_" . ""))
             #+(or genera gcl<2.7) '(("~@<" . "") ("; ~@;" . "; ") ("~@:>" . "") ("~:>" . ""))) :do
      (loop :for found = (search unsupported format) :while found :do
        (setf format (strcat (subseq format 0 found) replacement
                             (subseq format (+ found (length unsupported)))))))
    format)