;;; p-search-prior.el --- Implementation of search priors  -*- lexical-binding:t -*-

;;; Commentary:

;; This package implements various search priors to use in a p-search session.

;;; Code:

;;; Reader Functions

;; ToDo List:
;; File System:
;; - [ ] f n File Name
;; - [ ] f d Directory
;; - [ ] f t File Type
;; - [ ] f m Modification Date
;; - [ ] f s Size
;; - [ ] f c Distance
;;
;; Git:
;; - [ ] g a Author
;; - [ ] g b Branch
;; - [ ] g c File Co-Changes
;; - [ ] g m Modification Frequency
;; - [ ] g t Commit Time
;;
;; Vector:
;; - [ ] v d Vector Distance
;;
;; Emacs
;; - [ ] e b Open Buffer
;;
;; Source
;; - [ ] s t Text Match
;; - [ ] s c Co-located text match
;; - [ ] s f Text Frequency
;;
;; Source (Regexp)
;; - [ ] r t Regexp Text Match
;; - [ ] r c co-located regexp text match
;; - [ ] r f regexp frequency


(defun p-search-prior-default-arguments (template)
  "Return default input and options of TEMPLATE as one alist.
This function is primarily used to create the base prior with reasonable
default inputs, with the args being set to nil."
  (let* ((input-spec (oref template input-spec))
         (options-spec (oref template options-spec))
         (res '()))
    (pcase-dolist (`(,name . (,type . ,options)) input-spec)
      (let* ((default (plist-get options :default))
             (default-val (if (functionp default) (funcall default) default)))
        (setq res (cons
                   (cons name default-val)
                   res))))
    (pcase-dolist (`(,name . (,type . ,options)) options-spec)
      (let* ((default (plist-get options :default))
             (default-val (if (functionp default) (funcall default) default)))
        (setq res (cons
                   (cons name default-val)
                   res))))
    (nreverse res)))

;;;; Reference Priors:

(defconst p-search-prior-base--filesystem
  (p-search-prior-template-create
   :name "FILESYSTEM"
   :input-spec '((base-directory . (directory-name
                                    :key "d"
                                    :description "Directories"
                                    :default (lambda () default-directory)))
                 (filename-regexp . (regexp
                                     :key "f"
                                     :description "Filename Pattern"
                                     :default ".*")))
   :options-spec '((ignore . (regexp
                              :key "-i"
                              :description "Ignore Patterns"
                              :multiple t))  ;; TODO - implement multiple
                   (use-git-ignore . (toggle
                                      :key "-g"
                                      :description "Git Ignore"
                                      :default-value on)))
   :search-space-function
   (lambda (args)
     (let-alist args
       (let* ((default-directory .base-directory)
              (file-candidates (if .use-git-ignore
                                   (string-split (shell-command-to-string "git ls-files") "\n")
                                 (string-split (shell-command-to-string "find . -type f") "\n")))
              (files '()))
         (dolist (file file-candidates)
           (catch 'skip
             (when (string-prefix-p "./" file)
               (setq file (substring file 2)))
             (unless (or (equal .filename-regexp ".*")
                         (string-match-p .filename-regexp file))
               (throw 'skip nil))
             (when (and .ignore (string-match-p .ignore file))
               (throw 'skip nil))
             (setq file (file-name-concat default-directory file))
             (push file files)))
         (nreverse files))))))

(defconst p-search--subdirectory-prior-template
  (p-search-prior-template-create
   :name "subdirectory"
   :input-spec '((include-directories . (directory-names
                                         :key "i"
                                         :description "Directories"))))
  "Sample prior.")


(defconst p-search--filename-prior-template
  (p-search-prior-template-create
   :name "file-name"
   :input-spec '((include-filename . (regexp
                                      :key "i"
                                      :description "Pattern")))
   :initialize-function
   (lambda (prior base-prior-args args) ;; TODO - remove base-prior-args as it can be obtained from base prior and args for that mattr
     (let* ((files (p-search-generate-search-space))
            (fn-pattern (alist-get 'include-filename args))
            (result-ht (p-search-prior-results prior))) ;; normally should do async or lazily
       (dolist (file files)
         (puthash file (if (string-match-p fn-pattern file) 'yes 'no) result-ht)))
     (p-search--notify-main-thread)))))))

(defconst p-search--textsearch-prior-template
  (p-search-prior-template-create
   :name "text search"
   :input-spec
   '((search-term . (regexp :key "i" :description "Pattern")))
   :options-spec
   '((tool . (choice
              :key "-p"
              :description "search program"
              :choices
              (rg ;; TODO - how to specify defaults
               ag
               grep)))
     (strategy . (choice
                  :choices
                  (exact+case-insensitive+word-break
                   exact)
                  :key "-s"
                  :description "search scheme")))
   :initialize-function 'p-search--textsearch-prior-template-init
   :default-result 'no))

(defun p-search--textsearch-prior-template-init (prior base-prior-args args)
  (let* ((input (alist-get 'search-term args))
         (default-directory (alist-get 'base-directory base-prior-args)) ;; TODO: allow for multiple
         (ag-file-regex (alist-get 'filename-regexp base-prior-args))
         (cmd `("ag" ,input "-l" "--nocolor"))
         (buf (generate-new-buffer "*p-search-text-search*")))
    (when ag-file-regex
      (setq cmd (append cmd `("-G" ,ag-file-regex))))
    (make-process
     :name "p-search-text-search-prior"
     :buffer buf
     :command cmd
     :sentinel (lambda (proc event)
                 (when (or (member event '("finished\n" "deleted\n"))
                           (string-prefix-p "exited abnormally with code" event)
                           (string-prefix-p "failed with code"))
                   (p-search--notify-main-thread)))
     :filter (lambda (proc string)
               (when (buffer-live-p (process-buffer proc))
                 (with-current-buffer (process-buffer proc)
                   (let ((moving (= (point) (process-mark proc))))
                     (save-excursion
                       (goto-char (process-mark proc))
                       (insert string)
                       (set-marker (process-mark proc) (point)))
                     (if moving (goto-char (process-mark proc)))
                     (let ((files (string-split string "\n"))
                           (result-ht (p-search-prior-results prior)))
                       (dolist (f files)
                         (puthash (file-name-concat default-directory f) 'yes result-ht))))))))))

(defun p-seach--git-authors ()
  (let* ((base-args (oref p-search-base-prior arguments))
         (default-directory (alist-get 'base-directory base-args)))
    (string-lines (shell-command-to-string "git log --all --format='%aN' | sort -u") t)))

(defconst p-search--git-author-prior-template
  (p-search-prior-template-create
   :name "git author"
   :input-spec
   '((git-author . (choice
                    :key "a"
                    :description "Author"
                    :choices p-seach--git-authors)))
   :options-spec
   '()
   :initialize-function 'p-search--git-author-prior-template-init
   :default-result 'no))

(defun p-search--git-author-prior-template-init (prior base-prior-args args)
  (let* ((author (alist-get 'git-author args))
         (default-directory (alist-get 'base-directory base-prior-args))
         (buf (generate-new-buffer "*p-search-git-author-search*"))
         (git-command (format "git log --author=\"%s\" --name-only --pretty=format: | sort -u" author)))
    (make-process
     :name "p-seach-git-author-prior"
     :buffer buf
     :command `("sh" "-c" ,git-command)
     :sentinel (lambda (proc event)
                 (when (or (member event '("finished\n" "deleted\n"))
                           (string-prefix-p "exited abnormally with code" event)
                           (string-prefix-p "failed with code"))
                   (p-search--notify-main-thread)))
     :filter (lambda (proc string)
               (when (buffer-live-p (process-buffer proc))
                 (with-current-buffer (process-buffer proc)
                   (let ((moving (= (point) (process-mark proc))))
                     (save-excursion
                       (goto-char (process-mark proc))
                       (insert string)
                       (set-marker (process-mark proc) (point)))
                     (if moving (goto-char (process-mark proc)))
                     (let ((files (string-split string "\n"))
                           (result-ht (p-search-prior-results prior)))
                       (dolist (f files)
                         (puthash (file-name-concat default-directory f) 'yes result-ht))))))))))



;;; p-search-prior.el ends here
