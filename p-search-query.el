;;; p-search-query.el --- Query dispatcher for p-search -*- lexical-binding: t; -*-

;;; Commentary:

;;

;;; Code:

(require 'range)

(defun p-search-query-rg-escape (string)
  "Insert escape \\ characters in STRING based on Rust's regex parser (used in rg)."
  (let* ((meta-chars '(?\\ ?. ?+ ?* ?\? ?\( ?\) ?| ?\[ ?\] ?\{ ?\} ?^ ?$ ?# ?& ?- ?~))
         (ret-str (make-string (* (length string) 2) 0))
         (i 0))
    (dotimes (j (length string))
      (if (member (aref string j) meta-chars)
          (progn
            (aset ret-str i ?\\)
            (aset ret-str (1+ i) (aref string j))
            (cl-incf i 2))
        (aset ret-str i (aref string j))
        (cl-incf i)))
    (substring ret-str 0 i)))

(defun p-search-query-rg--term-regexp (string)
  "Create a term regular expression from STRING.
A term regex is noted for marking boundary characters."
  (list (list (concat "\\b" string "\\b") :case-insensitive t)
        (concat (capitalize (substring string 0 1))
                (substring string 1))))

(defun p-search-query-emacs--term-regexp (string)
  "Create a term regular expression from STRING.
A term regex is noted for marking boundary characters."
  (list (list (concat "\\<" string "\\>") :case-insensitive t)
        (concat (capitalize (substring string 0 1))
                (substring string 1))))


(defun p-search-query-rg--command (term)
  "Return command line arguments for rg search of TERM."
  (let* ((case-insensitive (p-search-query--metadata-get term :case-insensitive)))
    `("rg" "--count-matches" "--color" "never" "-i" ,@(and case-insensitive '("-i")) ,(p-search-query--metadata-elt term))))

(defun p-search-query-rg (string finalize-func)
  "Run query STRING using the rg tool.  Call FINALIZE-FUNC on obtained results."
  (let* ((terms (p-search-query-rg--term-regexp string))
         (commands (seq-map #'p-search-query-rg--command terms))
         (file-counts (make-hash-table :test #'equal))
         (proc-complete-ct 0))
    (dolist (cmd commands)
      (let* ((buf (generate-new-buffer (format "*p-search rg*")))) ;; TODO - better name
        (make-process
         :name "p-search-text-search"
         :buffer buf
         :command cmd
         :sentinel
         (lambda (proc event)
           (when (or (member event '("finished\n" "deleted\n"))
                     (string-prefix-p "exited abnormally with code" event)
                     (string-prefix-p "failed with code" event))
             (with-current-buffer (process-buffer proc)
               (let* ((files (string-split (buffer-string) "\n")))
                 (dolist (f files)
                   (when (string-match "^\\(.*\\):\\([0-9]*\\)$" f)
                     (let* ((fname (match-string 1 f))
                            (count (string-to-number (match-string 2 f))))
                       (puthash (file-name-concat default-directory fname) count file-counts))))
                 (cl-incf proc-complete-ct)
                 (when (= proc-complete-ct (length terms))
                   (funcall finalize-func file-counts)))))))))))

(defun p-search-query-and (results)
  "Return intersection of RESULTS, a vector of hash-tables."
  (let ((result (make-hash-table :test 'equal))
        (res1 (aref results 0)))
    (maphash
     (lambda (k v)
       (catch 'out
         (let* ((min-ct v)
                (i 1))
           (while (< i (length results))
             (let* ((val (gethash k (aref results i))))
               (unless val
                 (throw 'out nil))
               (when (< val min-ct)
                 (setq min-ct val)))

             (cl-incf i))
           ;; k is in all results
           (puthash k min-ct result))))
     res1)
    result))

;; let subqueries near dotimes

(defun p-search-query-near* (subqueries)
  "Return ranges in current buffer where SUBQUERIES are close to eachother."
  (let* ((ress '())
         (distance 15)) ;; TODO - make configurable
    (let* ((matches (seq-into (seq-map #'p-search-query-mark subqueries) 'vector)))
      (while (seq-every-p #'identity matches)
        (catch 'out
          (let* ((first-matches (seq-map #'car matches))
                 (ordered (seq-sort-by #'car #'< first-matches))
                 (betweens (seq-mapn (lambda (a b)
                                       (- (car b) (cdr a)))
                                     ordered (cdr ordered))))
            (dotimes (i (length betweens))
              ;; if any of the matching intervals are too big,
              ;; get the next matches of everything below the
              ;; too-big interval.
              (when (> (nth i betweens) distance)
                (dotimes (j (1+ i))
                  (let* ((elt (nth j ordered)))
                    (dotimes (k (length matches))
                      (when (equal elt (car (aref matches k)))
                        (aset matches k (cdr (aref matches k)))))))
                (throw 'out nil)))
            (push (cons (caar ordered)
                        (cdr (car (last ordered))))
                  ress)
            (dotimes (k (length matches))
              (when (equal (car ordered) (car (aref matches k)))
                (aset matches k (cdr (aref matches k)))))))))
    (setq ress (nreverse ress))
    ress))

(defun p-search-query-near (subqueries results)
  "Return subset of RESULTS where results of SUBQUERIES are close to eachother."
  (let* ((ress (make-hash-table :test #'equal))
         (intersect-results (p-search-query-and results)))
    (maphash
     (lambda (file _)
       (with-temp-buffer
         (insert-file-contents file)
         (let* ((matching-intervals (p-search-query-near* subqueries)))
           (puthash file (length matching-intervals) ress))))
     intersect-results)))

(defun p-search-query--metadata-add (elt md-key md-val)
  "Add metadata MD-KEY MD-VAL to ELT."
  (if (listp elt)
      (let* ((md (cdr elt))
             (new-md (plist-put md md-key md-val)))
        (cons elt new-md))
    (list elt md-key md-val)))

(defun p-search-query--metadata-get (elt md-key)
  "Return metadata value MD-KEY of ELT."
  (when (listp elt)
    (plist-get (cdr elt) md-key)))

(defun p-search-query--metadata-elt (elt)
  "Return original element of ELT."
  (if (listp elt)
      (car elt)
    elt))

(defun p-search-query-run (query &optional finalize-func)
  ""
  (pcase query
    (`(terms . ,elts)
     (let ((results (make-vector (length elts) nil))
           (i 0))
      (dolist (elt elts)
        (p-search-query-run
         elt
         (lambda (result)
           (aset results i result)
           (cl-incf i)
           (when (= i (length elts))
             (funcall finalize-func results)))))))
    ((cl-type string)
     (p-search-query-rg query finalize-func))
    (`(and . ,elts)
     (let ((results (make-vector (length elts) nil))
           (i 0))
      (dolist (elt elts)
        (p-search-query-run
         elt
         (lambda (result)
           (aset results i result)
           (cl-incf i)
           (when (= i (length elts))
             (let* ((and-res (p-search-query-and results)))
               (funcall finalize-func and-res))))))))
    (`(near . ,elts)
     (let ((results (make-vector (length elts) nil))
           (i 0))
      (dolist (elt elts)
        (p-search-query-run
         elt
         (lambda (result)
           (aset results i result)
           (cl-incf i)
           (when (= i (length elts))
             (let* ((near-res (p-search-query-near elts results)))
               (funcall finalize-func near-res))))))))
    (`(not ,elt)
     (p-search-query-run
      elt
      (lambda (result)
        (funcall
         finalize-func
         (p-search-query--metadata-add
          result :calc-type 'not)))))
    (`(must ,elt)
     (p-search-query-run
      elt
      (lambda (result)
        (funcall
         finalize-func
         (p-search-query--metadata-add
          result :calc-type 'must)))))
    (`(must-not ,elt)
     (p-search-query-run
      elt
      (lambda (result)
        (funcall
         finalize-func
         (p-search-query--metadata-add
          result :calc-type 'must-not)))))
    (`(boost . ,rest)
     (let* ((boost-elt (car rest))
            (boost-amt (or (nth 1 rest) 1)))
       (p-search-query-run
        boost-elt
        (lambda (result)
          (funcall
           finalize-func
           (p-search-query--metadata-add
            result :boost boost-amt))))))))

(defun p-search-query-bm25* (result-ht N total-size)
  "Calculate the BM25 scores of RESULT-HT, a map of file name to counts.
N is the total number of documents and TOTAL-SIZE is the sum of all files'
sizes."
  (let* ((docs-containing (hash-table-count (p-search-query--metadata-elt result-ht)))
         (total-counts 0)
         (scores (make-hash-table :test #'equal))
         (k1 1.2) ;; TODO - make customizable
         (b 0.75)) ;; TODO - make customizable
    (maphash (lambda (_ v) (cl-incf total-counts v)) (p-search-query--metadata-elt result-ht))
    (let* ((idf (log (+ (/ (+ N (- docs-containing) 0.5)
                           (+ docs-containing 0.5))
                        1)))
           (avg-size (/ (float total-size) N)))
      (maphash
       (lambda (file count)
         (let* ((size (nth 7 (file-attributes file)))
                (score (* idf (/ (* count (+ k1 1))
                                 (+ count (* k1 (+ 1 (- b) (* b (/ (float size) avg-size)))))))))
           (puthash file score scores)))
       (p-search-query--metadata-elt result-ht)))
    ;; TODO - consider boosts
    scores))

(defun p-search-query-bm25 (results N total-size)
  "Compute BM25 from RESULTS.
N is the number of documents and TOTAL-SIZE is the sum of the
sizes of all the documents."
  (let* ((total-scores (make-hash-table :test #'equal))
         (must-files (make-hash-table :test #'equal))
         (must-not-files (make-hash-table :test #'equal))
         (scores (seq-map (lambda (res)
                            (p-search-query-bm25* res N total-size))
                          results)))
    (dotimes (i (length scores))
      (let* ((count-ht (aref results i))
             (score-ht (nth i scores))
             (boost (or (p-search-query--metadata-get count-ht :boost) 1))
             (calc-type (p-search-query--metadata-get count-ht :calc-type)))
        (maphash
         (lambda (file score)
           (when (eql calc-type 'must)
             (puthash file t must-files))
           (when (eql calc-type 'must-not)
             (puthash file t must-not-files))
           (cond
            ((eql calc-type 'not)
             (puthash file (- (gethash file total-scores 0) (* score boost)) total-scores))
            (t
             (puthash file (+ (gethash file total-scores 0) (* score boost)) total-scores))))
         score-ht)
        (maphash
         (lambda (must-not-file _)
           (remhash must-not-file total-scores))
         must-not-files)
        (when (> (hash-table-count must-files) 0)
          (let* ((replace-total-scores (make-hash-table :test #'equal)))
            (maphash
             (lambda (must-file _)
               (puthash must-file (gethash must-file total-scores) replace-total-scores))
             must-files)
            (setq total-scores replace-total-scores)))))
    total-scores))



;;; Mark

(defun p-search-query-mark--term (string)
  "Find and return locations of STRING in buffer."
  (let* ((terms (p-search-query-emacs--term-regexp string))
         (ress '()))
    (dolist (term terms)
      (save-excursion
        (goto-char (point-min))
        (let* ((case-fold-search (p-search-query--metadata-get term :case-insensitive)))
          (while (search-forward-regexp (p-search-query--metadata-elt term) nil t)
            (push (cons (match-beginning 0) (match-end 0)) ress)))))
    (setq ress (nreverse ress))
    ress))

(defun p-search-query-mark (query)
  "Return intervals where QUERY matches content in current buffer."
  (pcase query
    (`(terms . ,elts)
     (let* ((ress '()))
       (dolist (elt elts)
         (let* ((res (p-search-query-mark elt)))
           (when res
             (setq ress (range-add-list ress res)))))
       ress))
    ((cl-type string)
     (p-search-query-mark--term query))
    (`(and . ,elts)
     (let* ((ress '()))
       (dolist (elt elts)
         (let* ((res (p-search-query-mark elt)))
           (when res
             (setq ress (range-add-list ress res)))))
       ress))
    (`(near . ,elts)
     (p-search-query-near* elts))
    (`(not ,_elt)
     (ignore))
    (`(must ,elt)
     (p-search-query-mark elt))
    (`(must-not ,_elt)
     (ignore))))

(defun p-search-query-scores-to-p-linear (scores)
  "Convert SCORES hashtable to hashtable of probabilities."
  ;; TODO - better algorithm...
  (let* ((max-score 0)
         (min-score most-positive-fixnum)
         (zero-score 0.4)
         (results (make-hash-table :test #'equal)))
    (maphash
     (lambda (_doc score)
       (when (> score max-score)
         (setq max-score score))
       (when (< score min-score)
         (setq min-score score)))
     scores)
    (maphash
     (lambda (doc score)
       (puthash doc (+ (* (/ (- 1.0 zero-score) (- max-score min-score)) score) zero-score) results))
     scores)
    results))


;;; Query Parser

(defun p-search-query-tokenize (query-str)
  (let* ((tokens '()))
    (with-temp-buffer
      (insert query-str)
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((eql (char-after (point)) ?\t)
          (forward-char 1))
         ((eql (char-after (point)) ?\s)
          (forward-char 1))
         ((member (char-after (point)) '(?+ ?- ?~ ?@ ?! ?^ ?/))
          (push (intern (char-to-string (char-after (point)))) tokens)
          (forward-char 1))
         ((eql (char-after (point)) ?\")
          (push 'quote tokens) ;; TODO
          (forward-char 1))
         ((eql (char-after (point)) ?\()
          (push 'lparen tokens)
          (forward-char 1))
         ((eql (char-after (point)) ?\))
          (push 'rparen tokens)
          (forward-char 1))
         ((looking-at-p "AND\\>")
          (push 'and tokens)
          (forward-char 3))
         (t
          (forward-char 1)))))
    (nreverse tokens)))





;;; scratch
(let* ((default-directory "/Users/zromero/dev/go/delve"))
  (p-search-query-run '(terms (must "text") (boost "node"))
                      (lambda (res)
                        (message "SCORES: %s" (p-search-query-bm25 res 1263 16682639))
                        (message "PROBS: %s" (p-search-query-scores-to-p-linear (p-search-query-bm25 res 1263 16682639))))))




"one two three"
'(terms "one" "two" "three")

"\"one two three\""
'(terms "one two three")

"student AND items"
'(terms (and "student" "items"))

"student !teacher"
'(terms "student" (not "teacher"))

"student^2"
'(terms (boost "student" 2))

"+student^"
'(terms (must (boost "student")))

"-(student teacher)"
'(terms (must-not (and "student" "teacher")))

"(student items)~"
'(terms (near "student" "items" ))

"(student items)~10w"
'(terms (near "student" "items" :distance 10 :unit word))

"title:.go"
'(terms (field "title" ".go"))

"string@items"
'(terms (syntax string "items"))

"teacher (string@items comment@this)~^ #title:(.html /.xmlx?/)"
'(terms "teacher"
        (boost
         (near (syntax string "items")
               (syntax comment "this")))
        (field "#title" (terms ".html"
                               (regexp ".xml?"))))

"comment@(this that)~"
'(terms (syntax comment (near "this" "that")))

;; terms: dispatch following terms
;;  "teacher": dispatch query for "teacher" ->
;;    <- a.txt: 2, b:txt: 3, y.txt: 1
;;  boost: run nested
;;    near: run each, find commonalities
;;      syntax string "items":
;;        <- test.go: 2, test2.go: 1
;;      syntax comment "this":
;;        <- test.go: 1, thest2.go: 3
;;      -> find intersection, manually look for near
;;      <- test.go: 1
;;    <- (test.go: 1 :modifiers (boost 2))
;;  field #title: run results and filter out manually
;;    terms:
;;      ".html": dispatch query for ".html"
;;        <- a.txt: 2, b.txt: 3
;;      (regexp ".xml?"): dispatch query for ".xml?"
;;        <- c.txt: 1
;;      <- a.txt: 2, b.txt: 3, c.txt: 1
;;     -> iterate results, running (terms ".html" (regexp ".xml?")) in emacs
;;        filtering if the match is in the correct field.

;; queries have two modes:
;; - locate :: must be able to return counts across search space.
;; - match  :: must be able to return match ranges for a particular item
;;
;; candidates must have the following methods:
;; - text :: return the text of candidate
;; - id   :: return the identifier of the candidate
;; - length :: return the length of the candidate
;;
;; Under normal circumstances, just the locate will be used for the
;; probability calculations.  Certain modifiers however may take the
;; union (terms) or intersection (and, near) and/or possibly run finer
;; grained filtering (syntax, field). The modified result counts will
;; be returned from this.  Take for example '(terms (syntax comment
;; (near "this" "that"))) The `near' directive will run queries on the
;; children elements, retrieving their file counts.  `near' will then
;; find their intersection and then for each element in the
;; intersection, call `match' for each element.  Then near will find
;; instances where they are close together, count them and return that
;; as its result.  Then, `syntax' will get the files where there are
;; near matches, go into them, call the match version of `near', and
;; then check if the match lies within the specified syntax.
;;
;; When the file results are displayed to the user, p-search will call
;; the match on the particular result, which would call the match
;; function of `syntax' which would call the match function of `near'.


(provide 'p-search-query)
;;; p-search-query.el ends here