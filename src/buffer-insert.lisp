(in-package :lem)

(export '(*inhibit-read-only*))

(defvar *inhibit-read-only* nil)

(define-buffer-local-and-global-hook before-change-functions)
(define-buffer-local-and-global-hook after-change-functions)

(defun check-read-only-at-point (line charpos offset)
  (unless *inhibit-read-only*
    (when (if (eql offset 0)
              (line-search-property line :read-only charpos)
              (line-search-property-range line
                                          :read-only
                                          charpos
                                          (if (null offset)
                                              nil
                                              (+ charpos offset))))
      (error 'read-only-error))))

(defmacro with-modify-buffer (buffer &body body)
  (alexandria:once-only (buffer)
    `(progn
       (unless *inhibit-read-only*
         (check-read-only-buffer ,buffer))
       (prog1 (progn ,@body)
         (buffer-modify ,buffer)))))

(defun shift-sticky-objects (buffer linum line charpos n)
  (line-property-insert-pos line charpos n)
  (dolist (m (buffer-points buffer))
    (when (and (= linum (point-linum m))
               (etypecase (point-kind m)
                 ((eql :left-inserting)
                  (<= charpos (point-charpos m)))
                 ((eql :right-inserting)
                  (< charpos (point-charpos m)))
                 ((eql :temporary)
                  nil)))
      (incf (point-charpos m) n))))

(defun shift-sticky-objects-newline (buffer linum line charpos)
  (line-property-insert-newline line (line-next line) charpos)
  (dolist (m (buffer-points buffer))
    (cond ((and (= (point-linum m) linum)
                (etypecase (point-kind m)
                  ((eql :left-inserting)
                   (<= charpos (point-charpos m)))
                  ((eql :right-inserting)
                   (< charpos (point-charpos m)))
                  ((eql :temporary)
                   nil)))
           (setf (point-line m) (line-next (point-line m)))
           (incf (point-linum m))
           (decf (point-charpos m) charpos))
          ((< linum (point-linum m))
           (incf (point-linum m))))))

(defun shift-sticky-objects-subtract (point n)
  (let ((line (point-line point))
        (linum (point-linum point))
        (charpos (point-charpos point))
        (buffer (point-buffer point)))
    (line-property-delete-pos line charpos n)
    (dolist (m (buffer-points buffer))
      (when (and (= linum (point-linum m))
                 (< charpos (point-charpos m)))
        (setf (point-charpos m)
              (if (> charpos (- (point-charpos m) n))
                  charpos
                  (- (point-charpos m) n)))))))

(defun shift-sticky-objects-subtract-line (point nextp)
  (let* ((line (point-line point))
         (linum (point-linum point))
         (charpos (point-charpos point))
         (buffer (point-buffer point)))
    (line-property-delete-line line charpos)
    (dolist (m (buffer-points buffer))
      (cond ((and (= linum (point-linum m))
                  (< charpos (point-charpos m)))
             (setf (point-charpos m) charpos))
            ((< linum (point-linum m))
             (when (eq (line-next line) (point-line m))
               (setf (point-line m) line)
               (incf (point-charpos m) (point-charpos point)))
             (decf (point-linum m)))))
    (when nextp
      (line-merge line (line-next line) charpos))))

(defun %insert-newline/point (buffer linum line charpos)
  (make-line line
             (line-next line)
             (subseq (line-str line) charpos))
  (shift-sticky-objects-newline buffer linum line charpos)
  (incf (buffer-nlines buffer))
  (setf (line-str line)
        (subseq (line-str line) 0 charpos)))

(defgeneric insert-char/point (point char)
  (:method (point char)
    (with-modify-buffer (point-buffer point)
      (check-read-only-at-point (point-line point) (point-charpos point) 0)
      (cond
        ((char= char #\newline)
         (%insert-newline/point (point-buffer point)
				(point-linum point)
                                (point-line point)
				(point-charpos point)))
        (t
         (let ((line (point-line point))
               (charpos (point-charpos point)))
           (shift-sticky-objects (point-buffer point) (point-linum point) line charpos 1)
           (setf (line-str line)
                 (concatenate 'string
                              (subseq (line-str line) 0 charpos)
                              (string char)
                              (subseq (line-str line) charpos))))))
      char)))

(defun %insert-line-string/point (buffer linum line charpos string)
  (check-read-only-at-point line charpos 0)
  (shift-sticky-objects buffer linum line charpos (length string))
  (setf (line-str line)
        (concatenate 'string
                     (subseq (line-str line) 0 charpos)
                     string
                     (subseq (line-str line) charpos))))

(defgeneric insert-string/point (point string)
  (:method (point string)
    (let ((buffer (point-buffer point)))
      (with-modify-buffer buffer
        (loop :with start := 0
              :for pos := (position #\newline string :start start)
              :for line := (point-line point) :then (line-next line)
              :for linum :from (point-linum point) :by 1
              :for charpos := (point-charpos point) :then 0
              :do (cond ((null pos)
                         (%insert-line-string/point buffer linum line charpos
                                                    (subseq string start))
                         (return))
                        (t
                         (let ((substr (subseq string start pos)))
                           (%insert-line-string/point buffer linum line charpos substr)
                           (%insert-newline/point buffer linum line
                                                  (+ charpos (length substr)))
                           (setf start (1+ pos))))))))
    string))

(defun %delete-line-between/point (point start end)
  (declare (special killring-stream line))
  (shift-sticky-objects-subtract point (- end start))
  (write-string (line-str line) killring-stream
                :start start
                :end end)
  (setf (line-str line)
        (concatenate 'string
                     (subseq (line-str line) 0 start)
                     (subseq (line-str line) end))))

(defun %delete-line-eol/point (point start)
  (declare (special killring-stream line))
  (shift-sticky-objects-subtract-line point nil)
  (write-string (line-str line) killring-stream :start start)
  (setf (line-str line)
        (subseq (line-str line) 0 start)))

(defun %delete-line/point (point start)
  (declare (special killring-stream line buffer n))
  (shift-sticky-objects-subtract-line point t)
  (write-string (line-str line) killring-stream :start start)
  (write-char #\newline killring-stream)
  (unless (eq n 'T)
    (decf n (1+ (- (line-length line) start))))
  (decf (buffer-nlines buffer))
  (setf (line-str line)
        (concatenate 'string
                     (subseq (line-str line) 0 start)
                     (line-str (line-next line))))
  (line-free (line-next line)))

(defgeneric delete-char/point (point n)
  (:method (point n)
    (declare (special n))
    (with-modify-buffer (point-buffer point)
      (with-output-to-string (killring-stream)
        (declare (special killring-stream))
        (let ((charpos (point-charpos point))
              (buffer (point-buffer point))
              (line (point-line point)))
          (declare (special buffer line))
          (loop :while (or (eq n 'T) (plusp n))
	     :for eolp := (or (eq n 'T)
			      (> n (- (line-length line) charpos)))
	     :do (check-read-only-at-point (point-line point)
                                           (point-charpos point)
                                           (if (eq n 'T) nil (if eolp n nil)))
	     :do (cond
		   ((not eolp)
		    (%delete-line-between/point point charpos (+ charpos n))
		    (return))
		   ((null (line-next line))
		    (%delete-line-eol/point point charpos)
		    (return))
		   (t
		    (%delete-line/point point charpos)))))))))


(defmethod insert-char/point :around (point char)
  (let ((offset (point-to-offset point)))
    (prog1 (call-next-method)
      (push-undo point
                 (lambda ()
                   (character-offset (buffer-start point) offset)
                   (save-excursion
                     (delete-char/point point 1))
                   point)))))

(defmethod insert-string/point :around (point string)
  (let ((offset (point-to-offset point)))
    (prog1 (call-next-method)
      (push-undo point
                 (lambda ()
                   (character-offset (buffer-start point) offset)
                   (save-excursion
                     (delete-char/point point (length string)))
                   point)))))

(defmethod delete-char/point :around (point n)
  (let ((offset (point-to-offset point))
        (string (call-next-method)))
    (push-undo point
               (lambda ()
                 (character-offset (buffer-start point) offset)
                 (save-excursion
                   (insert-string/point point string))
                 point))
    string))


(defmethod insert-char/point :before (point char)
  (when (before-change-functions)
    (with-point ((point point))
      (dolist (hook (before-change-functions))
        (funcall hook point 1)))))

(defmethod insert-string/point :before (point string)
  (when (before-change-functions)
    (with-point ((point point))
      (let ((length (length string)))
        (dolist (hook (before-change-functions))
          (funcall hook point length))))))

(defmethod delete-char/point :before (point n)
  (when (before-change-functions)
    (with-point ((point point))
      (dolist (hook (before-change-functions))
        (funcall hook point (- n))))))

(defmethod insert-char/point :after (point char)
  (when (after-change-functions)
    (with-point ((point point))
      (dolist (hook (after-change-functions))
        (funcall hook point)))))

(defmethod insert-string/point :after (point string)
  (when (after-change-functions)
    (with-point ((point point))
      (dolist (hook (after-change-functions))
        (funcall hook point)))))

(defmethod delete-char/point :after (point n)
  (when (after-change-functions)
    (with-point ((point point))
      (dolist (hook (after-change-functions))
        (funcall hook point)))))
