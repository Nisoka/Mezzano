;;;; John McCarthy 1927-2011

(in-package #:system.compiler)

(defparameter *suppress-builtins* nil
  "When T, the built-in functions will not be used and full calls will
be generated instead.")

(defvar *run-counter* nil)
(defvar *load-list* nil)
(defvar *r8-value* nil)
(defvar *stack-values* nil)
(defvar *for-value* nil)
(defvar *rename-list* nil)
(defvar *code-accum* nil)
(defvar *trailers* nil)
(defvar *environment* nil)
(defvar *environment-chain* nil)

(defun emit (&rest instructions)
  (dolist (i instructions)
    (push i *code-accum*)))

(defmacro emit-trailer ((&optional name) &body body)
  `(push (let ((*code-accum* '()))
	   ,(when name
		  `(emit ,name))
	   (progn ,@body)
	   (nreverse *code-accum*))
	 *trailers*))

(defun fixnum-to-raw (integer)
  (check-type integer (signed-byte 61))
  (* integer 8))

(defun character-to-raw (character)
  (check-type character character)
  (logior (ash (char-int character) 4) 10))

(defun codegen-lambda (lambda)
  (let ((*current-lambda* lambda)
	(*run-counter* 0)
	(*load-list* '())
	(*r8-value* nil)
	(*stack-values* (make-array 8 :fill-pointer 0 :adjustable t))
	(*for-value* t)
	(*rename-list* '())
	(*code-accum* '())
	(*trailers* '())
	(arg-registers '(:r8 :r9 :r10 :r11 :r12))
        (*environment-chain* '())
        (*environment* *environment*))
    (when (or (lambda-information-enable-keys lambda)
              (lambda-information-key-args lambda))
      (error "&KEY arguments did not get lowered!"))
    (when (> (+ (length (lambda-information-required-args lambda))
		(length (lambda-information-optional-args lambda)))
	     5)
      (format t "TODO: more than 5 required & optional arguments.~%")
      (return-from codegen-lambda (sys.int::assemble-lap `((sys.lap-x86:mov64 :r13 (:constant error))
							   (sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))
							   (sys.lap-x86:mov64 :r8 (:constant "TODO: more than 5 required & optional arguments."))
							   (sys.lap-x86:call (:symbol-function :r13))
							   (sys.lap-x86:ud2)))))
    ;; Save environment pointer.
    (when *environment*
      (let ((slot (find-stack-slot)))
        (setf (aref *stack-values* slot) (cons :environment :home))
        (push slot *environment-chain*)
        (emit `(sys.lap-x86:mov64 (:stack ,slot) :rbx))))
    (let ((env-size 0))
      ;; Count and place non-local lexical variables (environment size).
      (dolist (arg (lambda-information-required-args lambda))
        (when (and (lexical-variable-p arg)
                   (not (localp arg)))
          (incf env-size)))
      (dolist (arg (lambda-information-optional-args lambda))
        (when (and (lexical-variable-p (first arg))
                   (not (localp (first arg))))
          (incf env-size))
        (when (and (third arg)
                   (lexical-variable-p (third arg))
                   (not (localp (third arg))))
          (incf env-size)))
      (when (and (lambda-information-rest-arg lambda)
                 (lexical-variable-p (lambda-information-rest-arg lambda))
                 (not (localp (lambda-information-rest-arg lambda))))
        (incf env-size))
      (unless (zerop env-size)
        (push '() *environment*)
        ;; TODO: Check escaping stuff. My upward funargs D:
        ;; Allocate local environment on the stack.
        (emit `(sys.lap-x86:sub64 :csp ,(* (+ env-size 2 (if (evenp env-size) 0 1)) 8)))
        ;; Zero slots.
        (dotimes (i (1+ env-size))
          (emit `(sys.lap-x86:mov64 (:csp ,(* (1+ i) 8)) 0)))
        ;; Initialize the header. Simple-vector uses tag 0.
        (emit `(sys.lap-x86:mov64 (:csp) ,(ash (1+ env-size) 8))
              ;; Get value.
              `(sys.lap-x86:lea64 :rbx (:csp #b0111)))
        (when *environment-chain*
          ;; Auch. Stash R8.
          (emit `(sys.lap-x86:mov64 (:lsp -8) nil)
                `(sys.lap-x86:sub64 :lsp 8)
                `(sys.lap-x86:mov64 (:lsp 0) :r8)
                ;; Fetch saved environment link.
                `(sys.lap-x86:mov64 :r8 (:stack ,(first *environment-chain*)))
                `(sys.lap-x86:mov64 (:rbx 1) :r8)
                ;; Restore R8.
                `(sys.lap-x86:mov64 :r8 (:lsp 0))
                `(sys.lap-x86:add64 :lsp 8)))
        (let ((slot (find-stack-slot)))
          (setf (aref *stack-values* slot) (cons :environment :home))
          (push slot *environment-chain*)
          (emit `(sys.lap-x86:mov64 (:stack ,slot) :rbx))))
      ;; Compile argument setup code.
      (let ((current-arg-index 0))
        ;; Environemnt vector is in :RBX for required arguments.
        (dolist (arg (lambda-information-required-args lambda))
          (incf current-arg-index)
          (cond ((and (lexical-variable-p arg)
                      (localp arg))
                 (let ((ofs (find-stack-slot)))
                   (setf (aref *stack-values* ofs) (cons arg :home))
                   (emit `(sys.lap-x86:mov64 (:stack ,ofs) ,(pop arg-registers)))))
                ((lexical-variable-p arg)
                 ;; Non-local variable.
                 ;; +1 to align on the data. Backlink is skipped by magic.
                 (emit `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size (length (first *environment*))) 8)))
                                           ,(pop arg-registers)))
                 (push arg (first *environment*)))
                (t (return-from codegen-lambda
                     (sys.int::assemble-lap `((sys.lap-x86:mov64 :r13 (:constant error))
                                              (sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))
                                              (sys.lap-x86:mov64 :r8 (:constant "TODO: special required variables"))
                                              (sys.lap-x86:call (:symbol-function :r13))
                                              (sys.lap-x86:ud2)))))))
        ;; Need to load environment vector for optional args because the
        ;; initializer may trash :RBX.
        (dolist (arg (lambda-information-optional-args lambda))
          (when (or (not (lexical-variable-p (first arg)))
                    (and (third arg)
                         (not (lexical-variable-p (third arg)))))
            (sys.int::assemble-lap `((sys.lap-x86:mov64 :r13 (:constant error))
                                     (sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))
                                     (sys.lap-x86:mov64 :r8 (:constant "TODO: special variables. &OPTIONAL"))
                                     (sys.lap-x86:call (:symbol-function :r13))
                                     (sys.lap-x86:ud2))))
          (let ((mid-label (gensym))
                (end-label (gensym))
                (var-ofs nil)
                (sup-ofs nil))
            (when (localp (first arg))
              (setf var-ofs (find-stack-slot))
              (setf (aref *stack-values* var-ofs) (cons (first arg) :home)))
            (when (and (third arg)
                       (localp (third arg)))
              (setf sup-ofs (find-stack-slot))
              (setf (aref *stack-values* sup-ofs) (cons (third arg) :home)))
            ;; Check if this argument was supplied.
            (emit `(sys.lap-x86:cmp64 (:cfp -24) ,(fixnum-to-raw current-arg-index))
                  `(sys.lap-x86:jle ,mid-label))
            ;; Argument supplied, stash wherever.
            (cond (var-ofs
                   ;; Local var.
                   (emit `(sys.lap-x86:mov64 (:stack ,var-ofs) ,(pop arg-registers))))
                  (t ;; Non-local var. RBX will still be valid.
                   ;; +1 to align on the data. Backlink is skipped by magic.
                   (setf var-ofs (length (first *environment*)))
                   (emit `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size var-ofs) 8)))
                                             ,(pop arg-registers)))
                   (push (first arg) (first *environment*))))
            (when (third arg)
              (cond (sup-ofs
                     (emit `(sys.lap-x86:mov64 (:stack ,sup-ofs) t)))
                    (t ;; Non-local var. RBX will still be valid.
                     ;; +1 to align on the data. Backlink is skipped by magic.
                     (setf sup-ofs (length (first *environment*)))
                     (emit `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size sup-ofs) 8)))
                                               ,t))
                     (push (third arg) (first *environment*)))))
            (emit `(sys.lap-x86:jmp ,end-label)
                  mid-label)
            ;; Argument not supplied. Evaluate init-form.
            (let ((tag (cg-form (second arg))))
              (load-in-r8 tag t)
              (setf *r8-value* nil)
              ;; Possibly reload the environment.
              (when (or (not (localp (first arg)))
                        (and (third arg)
                             (not (localp (third arg)))))
                (emit `(sys.lap-x86:mov64 :rbx (:stack ,(first *environment-chain*)))))
              (cond ((localp (first arg))
                     ;; Local var.
                     (emit `(sys.lap-x86:mov64 (:stack ,var-ofs) :r8)))
                    (t ;; Non-local var. RBX will still be valid.
                     ;; +1 to align on the data. Backlink is skipped by magic.
                     (emit `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size var-ofs) 8)))
                                               ,:r8))))
              (when (third arg)
                (cond ((localp (third arg))
                       (emit `(sys.lap-x86:mov64 (:stack ,sup-ofs) nil)))
                      (t ;; Non-local var. RBX will still be valid.
                       ;; +1 to align on the data. Backlink is skipped by magic.
                       (emit `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size sup-ofs) 8)))
                                               ,t))))))
            (emit end-label)
            (incf current-arg-index))))
      (let ((rest-arg (lambda-information-rest-arg lambda)))
        (when (and rest-arg
                   ;; Avoid generating code &REST code when the variable isn't used.
                   (not (and (lexical-variable-p rest-arg)
                             (zerop (lexical-variable-use-count rest-arg)))))
          (unless (lexical-variable-p rest-arg)
            (return-from codegen-lambda
              (sys.int::assemble-lap `((sys.lap-x86:mov64 :r13 (:constant error))
                                       (sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))
                                       (sys.lap-x86:mov64 :r8 (:constant "TODO: special variables. &REST"))
                                       (sys.lap-x86:call (:symbol-function :r13))
                                       (sys.lap-x86:ud2)))))
          (cond ((localp rest-arg)
                 (let ((ofs (find-stack-slot)))
                   (setf (aref *stack-values* ofs) (cons rest-arg :home))
                   (emit `(sys.lap-x86:mov64 (:stack ,ofs) :r13))))
                ((lexical-variable-p rest-arg)
                 ;; Non-local variable.
                 ;; +1 to align on the data. Backlink is skipped by magic.
                 (emit `(sys.lap-x86:mov64 :rbx (:stack ,(first *environment-chain*)))
                       `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (- env-size (length (first *environment*))) 8)))
                                           :r13))
                 (push rest-arg (first *environment*)))))))
    (let ((code-tag (let ((*for-value* :multiple))
                      (cg-form `(progn ,@(lambda-information-body lambda))))))
      (when code-tag
        (cond ((eql code-tag :multiple)
               ;; FIXME. Not right when >5 arguments are supplied.
               (emit `(sys.lap-x86:mov64 :rbx :lfp)
                     `(sys.lap-x86:mov64 :lfp (:cfp -8))
                     `(sys.lap-x86:leave)
                     `(sys.lap-x86:ret)))
              (t (load-in-r8 code-tag t)
                 ;; FIXME. Not right when >5 arguments are supplied.
                 (emit `(sys.lap-x86:mov64 :rbx :lfp)
                       `(sys.lap-x86:mov64 :lfp (:cfp -8))
                       `(sys.lap-x86:mov32 :ecx 1)
                       `(sys.lap-x86:leave)
                       `(sys.lap-x86:ret))))))
    (sys.int::assemble-lap (nconc
			    (generate-entry-code lambda)
			    (nreverse *code-accum*)
			    (apply #'nconc *trailers*)))))

(defun generate-entry-code (lambda)
  (let ((entry-label (gensym "ENTRY"))
	(invalid-arguments-label (gensym "BADARGS")))
    (push (list `(sys.lap-x86:ud2)
                invalid-arguments-label
		`(sys.lap-x86:mov64 :r13 (:constant sys.int::%invalid-argument-error))
		`(sys.lap-x86:call (:symbol-function :r13)))
	  *trailers*)
    (nconc
     (list entry-label
	   ;; Create control stack frame.
	   `(sys.lap-x86:push :cfp)
	   `(sys.lap-x86:mov64 :cfp :csp)
	   ;; Save old LFP.
	   `(sys.lap-x86:push :lfp)
	   ;; Function object.
	   `(sys.lap-x86:lea64 :rax (:rip ,entry-label))
	   `(sys.lap-x86:push :rax)
	   ;; Saved argument count.
	   `(sys.lap-x86:push :rcx)
	   ;; Stack alignment/spare (used by the rest code).
	   `(sys.lap-x86:push 0))
     ;; Emit the argument count test.
     (cond ((lambda-information-rest-arg lambda)
	    ;; If there are no required parameters, then don't generate a lower-bound check.
	    (when (lambda-information-required-args lambda)
	      ;; Minimum number of arguments.
	      (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		    `(sys.lap-x86:jl ,invalid-arguments-label))))
	   ((and (lambda-information-required-args lambda)
		 (lambda-information-optional-args lambda))
	    ;; A range.
	    (list `(sys.lap-x86:sub32 :ecx ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		  `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-optional-args lambda))))
		  `(sys.lap-x86:ja ,invalid-arguments-label)))
	   ((lambda-information-optional-args lambda)
	    ;; Maximum number of arguments.
	    (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-optional-args lambda))))
		  `(sys.lap-x86:ja ,invalid-arguments-label)))
	   ((lambda-information-required-args lambda)
	    ;; Exact number of arguments.
	    (list `(sys.lap-x86:cmp32 :ecx ,(fixnum-to-raw (length (lambda-information-required-args lambda))))
		  `(sys.lap-x86:jne ,invalid-arguments-label)))
	   ;; No arguments
	   (t (list `(sys.lap-x86:test32 :ecx :ecx)
		    `(sys.lap-x86:jnz ,invalid-arguments-label))))
     (when (and (lambda-information-rest-arg lambda)
                ;; Avoid generating code &REST code when the variable isn't used.
                (not (and (lexical-variable-p (lambda-information-rest-arg lambda))
                          (zerop (lexical-variable-use-count (lambda-information-rest-arg lambda))))))
       (let ((regular-argument-count (+ (length (lambda-information-required-args lambda))
					(length (lambda-information-optional-args lambda))))
	     (rest-loop-head (gensym "REST-LOOP-HEAD"))
	     (rest-loop-test (gensym "REST-LOOP-TEST"))
	     (pop-args-over (gensym "POP-ARGS-OVER"))
             (dx-rest (lexical-variable-dynamic-extent (lambda-information-rest-arg lambda))))
	 ;; Assemble the rest list into r13.
	 (nconc
	  ;; Push all argument registers and create two scratch stack slots.
	  ;; Eight total slots.
	  ;; This should be clamped to the actual number of arguments
	  ;; but it doesn't really matter.
	  (let ((result '()))
	    (dotimes (i 8 result)
	      (push `(sys.lap-x86:mov64 (:lsp ,(- (* (1+ i) 8))) nil) result)))
	  (list `(sys.lap-x86:sub64 :lsp ,(* 8 8)))
	  (let ((i 1))
	    (mapcar #'(lambda (x)
			`(sys.lap-x86:mov64 (:lsp ,(* (incf i) 8)) ,x))
		    '(:rbx :r8 :r9 :r10 :r11 :r12)))
	  (list
	   ;; Number of arguments processed.
	   `(sys.lap-x86:mov64 (:cfp -32) ,(fixnum-to-raw regular-argument-count)))
	   ;; Create the result cell.
          (cond
            (dx-rest
             (list `(sys.lap-x86:sub64 :csp 16)
                   `(sys.lap-x86:mov64 (:csp 0) nil)
                   `(sys.lap-x86:mov64 (:csp 8) nil)
                   `(sys.lap-x86:lea64 :r8 (:csp 1))))
            (t
             (list `(sys.lap-x86:mov64 :r8 nil)
                   `(sys.lap-x86:mov64 :r9 :r8)
                   `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
                   `(sys.lap-x86:mov64 :r13 (:constant cons))
                   `(sys.lap-x86:call (:symbol-function :r13))
                   `(sys.lap-x86:mov64 :lsp :rbx))))
          (list
           ;; Stash in the result slot and the scratch slot.
           `(sys.lap-x86:mov64 (:lsp) :r8)
	   `(sys.lap-x86:mov64 (:lsp 8) :r8)
	   ;; Now walk the arguments, adding to the list.
	   `(sys.lap-x86:mov64 :rax (:cfp -32))
	   `(sys.lap-x86:jmp ,rest-loop-test)
	   rest-loop-head)
          ;; Create a new cons.
          (cond
            (dx-rest
             (list `(sys.lap-x86:sub64 :csp 16)
                   `(sys.lap-x86:mov64 (:csp 0) nil)
                   `(sys.lap-x86:mov64 (:csp 8) nil)
                   `(sys.lap-x86:lea64 :r8 (:csp 1))
                   `(sys.lap-x86:mov64 :r9 (:lsp :rax 24))
                   `(sys.lap-x86:add64 :rax ,(fixnum-to-raw 1))
                   `(sys.lap-x86:mov64 (:cfp -32) :rax)
                   `(sys.lap-x86:mov64 (:car :r8) :r9)))
            (t
             (list `(sys.lap-x86:mov64 :r8 (:lsp :rax 24))
                   `(sys.lap-x86:mov64 :r9 nil)
                   `(sys.lap-x86:add64 :rax ,(fixnum-to-raw 1))
                   `(sys.lap-x86:mov64 (:cfp -32) :rax)
                   `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
                   `(sys.lap-x86:mov64 :r13 (:constant cons))
                   `(sys.lap-x86:call (:symbol-function :r13))
                   `(sys.lap-x86:mov64 :lsp :rbx))))
          (list
	   `(sys.lap-x86:mov64 :r9 (:lsp))
	   `(sys.lap-x86:mov64 (:cdr :r9) :r8)
	   `(sys.lap-x86:mov64 (:lsp) :r8)
	   `(sys.lap-x86:mov64 :rax (:cfp -32))
	   rest-loop-test
	   `(sys.lap-x86:cmp64 :rax (:cfp -24))
	   `(sys.lap-x86:jl ,rest-loop-head)
	   ;; The rest list has been created!
	   ;; Now store it in R13 and restore the other registers.
	   `(sys.lap-x86:mov64 :r13 (:lsp 8))
	   `(sys.lap-x86:mov64 :r13 (:cdr :r13))
	   `(sys.lap-x86:mov64 :rbx (:lsp 16))
	   `(sys.lap-x86:mov64 :r8 (:lsp 24))
	   `(sys.lap-x86:mov64 :r9 (:lsp 32))
	   `(sys.lap-x86:mov64 :r10 (:lsp 40))
	   `(sys.lap-x86:mov64 :r11 (:lsp 48))
	   `(sys.lap-x86:mov64 :r12 (:lsp 56))
	   ;; Pop all the arguments off and the two scrach slots.
	   `(sys.lap-x86:add64 :lsp ,(* 8 8))
	   `(sys.lap-x86:mov64 :rax (:cfp -24))
	   `(sys.lap-x86:sub64 :rax ,(fixnum-to-raw 5))
	   `(sys.lap-x86:cmp64 :rax 0)
	   `(sys.lap-x86:jl ,pop-args-over)
	   `(sys.lap-x86:add64 :lsp :rax)
	   pop-args-over))))
     ;; No arguments on the stack at this point.
     (list `(sys.lap-x86:mov64 :lfp :lsp))
     ;; Flush stack slots.
     (let ((result '()))
       (dotimes (i (length *stack-values*) result)
	 (push `(sys.lap-x86:mov64 (:lfp ,(- (* (1+ i) 8))) nil) result)))
     (unless (zerop (length *stack-values*))
       (list `(sys.lap-x86:sub64 :lsp ,(* (length *stack-values*) 8)))))))

(defun cg-form (form)
  (flet ((save-tag (tag)
	   (when (and tag *for-value* (not (keywordp tag)))
	     (push tag *load-list*))
	   tag))
    (etypecase form
      (cons (case (first form)
	      ((block) (save-tag (cg-block form)))
	      ((go) (cg-go form))
	      ((if) (save-tag (cg-if form)))
	      ((let) (cg-let form))
	      ((load-time-value) (cg-load-time-value form))
	      ((multiple-value-bind) (save-tag (cg-multiple-value-bind form)))
	      ((multiple-value-call) (save-tag (cg-multiple-value-call form)))
	      ((multiple-value-prog1) (cg-multiple-value-prog1 form))
	      ((progn) (cg-progn form))
	      ((progv) (cg-progv form))
	      ((quote) (cg-quote form))
	      ((return-from) (cg-return-from form))
	      ((setq) (cg-setq form))
	      ((tagbody) (cg-tagbody form))
	      ((the) (cg-the form))
	      ((unwind-protect) (cg-unwind-protect form))
	      (t (save-tag (cg-function-form form)))))
      (lexical-variable
       (save-tag (cg-variable form)))
      (lambda-information
       (let ((tag (cg-lambda form)))
         (when (and (consp tag)
                    (symbolp (car tag))
                    (null (cdr tag))
                    (not (eql 'quote (car tag))))
           (save-tag tag))
         tag)))))

;;; TODO: Unwinding over special bindings (let, progv and unwind-protect).
(defun cg-block (form)
  (when (not (localp (second form)))
    (return-from cg-block (cg-form '(error '"TODO: Escaping blocks."))))
  (let* ((label (gensym))
	 (*rename-list* (cons (list (second form)
                                    label
                                    (if (eql *for-value* :predicate)
                                        t
                                        *for-value*)
                                    0) *rename-list*))
	 (stack-slots (set-up-for-branch))
	 (tag (cg-form `(progn ,@(cddr form)))))
    (cond ((and *for-value* tag (/= (fourth (first *rename-list*)) 0))
	   ;; Returning a value, exit is reached normally and there were return-from forms reached.
           (case *for-value*
             (:predicate
              (cond ((keywordp tag)
                     (load-predicate tag))
                    (t (load-in-r8 tag t)
                       (smash-r8)))
              (emit label)
              (setf *stack-values* (copy-stack-values stack-slots)
                    *r8-value* (list (gensym))))
             (:multiple
              (unless (eql tag :multiple)
                (load-multiple-values tag)
                (smash-r8))
              (emit label)
              (setf *stack-values* (copy-stack-values stack-slots)
                    *r8-value* :multiple))
             (t (load-in-r8 tag t)
                (smash-r8)
                (emit label)
                (setf *stack-values* (copy-stack-values stack-slots)
                      *r8-value* (list (gensym))))))
	  ((and *for-value* tag)
	   ;; Returning a value, exit is reached normally, but no return-from forms were reached.
	   tag)
	  ((and *for-value* (/= (fourth (first *rename-list*)) 0))
	   ;; Returning a value, exit is not reached normally, but there were return-from forms reached.
	   (smash-r8)
	   (emit label)
	   (setf *stack-values* (copy-stack-values stack-slots)
		 *r8-value* (if (eql *for-value* :multiple)
                                :multiple
                                (list (gensym)))))
	  ((/= (fourth (first *rename-list*)) 0)
	   ;; Not returning a value, but there were return-from forms reached.
	   (smash-r8)
           (emit label)
	   (setf *stack-values* (copy-stack-values stack-slots)
		 *r8-value* (list (gensym))))
          ;; No value returned, no return-from forms reached.
	  (t nil))))

(defun cg-go (form)
  (smash-r8)
  (emit `(sys.lap-x86:jmp ,(second (assoc (second form) *rename-list*))))
  'nil)

(defun branch-to (label))
(defun emit-label (label)
  (emit label))

(defun tag-saved-on-stack-p (tag)
  (dotimes (i (length *stack-values*) nil)
    (let ((x (aref *stack-values* i)))
      (when (or (eq tag x)
		(and (consp tag) (consp x)
		     (eql (car tag) (car x))
		     (eql (cdr tag) (cdr x))))
	(return t)))))

(defun set-up-for-branch ()
  ;; Save variables on the load list that might be modified to the stack.
  (smash-r8)
  (dolist (l *load-list*)
    (when (and (consp l) (lexical-variable-p (car l))
	       (not (eql (lexical-variable-write-count (car l)) 0)))
      ;; Don't save if there is something satisfying this already.
      (multiple-value-bind (loc true-tag)
	  (value-location l)
	(declare (ignore loc))
	(unless (tag-saved-on-stack-p true-tag)
	  (load-in-r8 l nil)
	  (smash-r8 t)))))
  (let ((new-values (make-array (length *stack-values*) :initial-contents *stack-values*)))
    ;; Now flush any values that aren't there to satisfy the load list.
    (dotimes (i (length new-values))
      (when (condemed-p (aref new-values i))
	(setf (aref new-values i) nil)))
    new-values))

(defun copy-stack-values (values)
  "Copy the VALUES array, ensuring that it's at least as long as the current *stack-values* and is adjustable."
  (let ((new (make-array (length *stack-values*) :adjustable t :fill-pointer t :initial-element nil)))
    (dotimes (i (length values))
      (setf (aref new i) (aref values i)))
    new))

;;; (predicate inverse jump-instruction cmov-instruction)
(defparameter *predicate-instructions*
  '((:o  :no  sys.lap-x86:jo   sys.lap-x86:cmov64o)
    (:no :o   sys.lap-x86:jno  sys.lap-x86:cmov64no)
    (:b  :nb  sys.lap-x86:jb   sys.lap-x86:cmov64b)
    (:nb :b   sys.lap-x86:jnb  sys.lap-x86:cmov64nb)
    (:c  :nc  sys.lap-x86:jc   sys.lap-x86:cmov64c)
    (:nc :c   sys.lap-x86:jnc  sys.lap-x86:cmov64nc)
    (:ae :nae sys.lap-x86:jae  sys.lap-x86:cmov64ae)
    (:nae :ae sys.lap-x86:jnae sys.lap-x86:cmov64nae)
    (:e  :ne  sys.lap-x86:je   sys.lap-x86:cmov64e)
    (:ne :e   sys.lap-x86:jne  sys.lap-x86:cmov64ne)
    (:z  :nz  sys.lap-x86:jz   sys.lap-x86:cmov64z)
    (:nz :z   sys.lap-x86:jnz  sys.lap-x86:cmov64nz)
    (:be :nbe sys.lap-x86:jbe  sys.lap-x86:cmov64be)
    (:nbe :be sys.lap-x86:jnbe sys.lap-x86:cmov64nbe)
    (:a  :na  sys.lap-x86:ja   sys.lap-x86:cmov64a)
    (:na :a   sys.lap-x86:jna  sys.lap-x86:cmov64na)
    (:s  :ns  sys.lap-x86:js   sys.lap-x86:cmov64s)
    (:ns :s   sys.lap-x86:jns  sys.lap-x86:cmov64ns)
    (:p  :np  sys.lap-x86:jp   sys.lap-x86:cmov64p)
    (:np :p   sys.lap-x86:jnp  sys.lap-x86:cmov64np)
    (:pe :po  sys.lap-x86:jpe  sys.lap-x86:cmov64pe)
    (:po :pe  sys.lap-x86:jpo  sys.lap-x86:cmov64po)
    (:l  :nl  sys.lap-x86:jl   sys.lap-x86:cmov64l)
    (:nl :l   sys.lap-x86:jnl  sys.lap-x86:cmov64nl)
    (:ge :nge sys.lap-x86:jge  sys.lap-x86:cmov64ge)
    (:nge :ge sys.lap-x86:jnge sys.lap-x86:cmov64nge)
    (:le :nle sys.lap-x86:jle  sys.lap-x86:cmov64le)
    (:nle :le sys.lap-x86:jnle sys.lap-x86:cmov64nle)
    (:g  :ng  sys.lap-x86:jg   sys.lap-x86:cmov64g)
    (:ng :g   sys.lap-x86:jng  sys.lap-x86:cmov64ng)))

(defun predicate-info (pred)
  (or (assoc pred *predicate-instructions*)
      (error "Unknown predicate ~S." pred)))

(defun invert-predicate (pred)
  (second (predicate-info pred)))

(defun load-predicate (pred)
  (smash-r8)
  (emit `(sys.lap-x86:mov64 :r8 nil)
        `(sys.lap-x86:mov64 :r9 t)
        `(,(fourth (predicate-info pred)) :r8 :r9)))

(defun predicate-result (pred)
  (cond ((eql *for-value* :predicate)
         pred)
        (t (load-predicate pred)
           (setf *r8-value* (list (gensym))))))

(defun cg-if (form)
  (let* ((else-label (gensym))
	 (end-label (gensym))
	 (test-tag (let ((*for-value* :predicate))
		     (cg-form (second form))))
	 (branch-count 0)
	 (stack-slots (set-up-for-branch))
	 (loc (when (and test-tag (not (keywordp test-tag)))
                (value-location test-tag t))))
    (when (null test-tag)
      (return-from cg-if))
    (cond ((keywordp test-tag)) ; Nothing for predicates.
          ((and (consp loc) (eq (first loc) :stack))
	   (emit `(sys.lap-x86:cmp64 (:stack ,(second loc)) nil)))
	  (t (load-in-r8 test-tag)
	     (emit `(sys.lap-x86:cmp64 :r8 nil))))
    (let ((r8-at-cond *r8-value*)
	  (stack-at-cond (make-array (length *stack-values*) :initial-contents *stack-values*)))
      ;; This is a little dangerous and relies on SET-UP-FOR-BRANCH not
      ;; changing the flags.
      (cond ((keywordp test-tag)
             ;; Invert the sense.
             (emit `(,(third (predicate-info (invert-predicate test-tag))) ,else-label)))
            (t (emit `(sys.lap-x86:je ,else-label))))
      (branch-to else-label)
      (let ((tag (cg-form (third form))))
	(when tag
	  (when *for-value*
            (case *for-value*
              (:multiple (load-multiple-values tag))
              (:predicate (if (keywordp tag)
                              (load-predicate tag)
                              (load-in-r8 tag t)))
              (t (load-in-r8 tag t))))
	  (emit `(sys.lap-x86:jmp ,end-label))
	  (incf branch-count)
	  (branch-to end-label)))
      (setf *r8-value* r8-at-cond
	    *stack-values* (copy-stack-values stack-at-cond))
      (emit-label else-label)
      (let ((tag (cg-form (fourth form))))
	(when tag
	  (when *for-value*
            (case *for-value*
              (:multiple (load-multiple-values tag))
              (:predicate (if (keywordp tag)
                              (load-predicate tag)
                              (load-in-r8 tag t)))
              (t (load-in-r8 tag t))))
	  (incf branch-count)
	  (branch-to end-label)))
      (emit-label end-label)
      (setf *stack-values* (copy-stack-values stack-slots))
      (unless (zerop branch-count)
	(setf *r8-value* (if (eql *for-value* :multiple)
                             :multiple
                             (list (gensym))))))))

(defun localp (var)
  (or (null (lexical-variable-used-in var))
      (and (null (cdr (lexical-variable-used-in var)))
	   (eq (car (lexical-variable-used-in var)) (lexical-variable-definition-point var)))))

(defun cg-let (form)
  (let* ((bindings (second form))
         (variables (mapcar 'first bindings))
         (body (cddr form)))
    (when (some 'symbolp variables)
      (return-from cg-let (cg-form `(error '"TODO complex let binding"))))
    (let ((env-size (count-if (lambda (x) (and (lexical-variable-p x) (not (localp x)))) variables))
          (*environment* *environment*)
          (*environment-chain* *environment-chain*))
      (unless (zerop env-size)
        (push (remove-if 'localp variables) *environment*)
        ;; TODO: Check escaping stuff. My upward funargs D:
        ;; Allocate local environment on the stack.
        (emit `(sys.lap-x86:sub64 :csp ,(* (+ env-size 2 (if (evenp env-size) 0 1)) 8)))
        ;; Zero slots.
        (dotimes (i (1+ env-size))
          (emit `(sys.lap-x86:mov64 (:csp ,(* (1+ i) 8)) 0)))
        ;; Initialize the header. Simple-vector uses tag 0.
        (emit `(sys.lap-x86:mov64 (:csp) ,(ash (1+ env-size) 8))
              ;; Get value.
              `(sys.lap-x86:lea64 :rbx (:csp #b0111)))
        (when *environment-chain*
          ;; Set back-link.
          (emit `(sys.lap-x86:mov64 :r8 (:stack ,(first *environment-chain*)))
                `(sys.lap-x86:mov64 (:rbx 1) :r8)))
        (let ((slot (find-stack-slot)))
          (setf (aref *stack-values* slot) (cons :environment :home))
          (push slot *environment-chain*)
          (emit `(sys.lap-x86:mov64 (:stack ,slot) :rbx))))
      (dolist (b (second form))
        (let* ((var (first b))
               (init-form (second b)))
          (cond ((zerop (lexical-variable-use-count var))
                 (let ((*for-value* nil))
                   (cg-form init-form)))
                ((localp var)
                 (let ((slot (find-stack-slot)))
                   (setf (aref *stack-values* slot) (cons var :home))
                   (let* ((*for-value* t)
                          (tag (cg-form init-form)))
                     (load-in-r8 tag t)
                     (setf *r8-value* (cons var :dup))
                         (emit `(sys.lap-x86:mov64 (:stack ,slot) :r8)))))
                (t (let* ((env-slot (position var (first *environment*)))
                          (*for-value* t)
                          (tag (cg-form init-form)))
                     (load-in-r8 tag t)
                     (emit `(sys.lap-x86:mov64 :rbx (:stack ,(first *environment-chain*)))
                           `(sys.lap-x86:mov64 (:rbx ,(+ 1 (* (1+ env-slot) 8)))
                                               :r8)))))))
      (cg-form `(progn ,@body)))))

;;;(defun cg-load-time-value (form))

(defun cg-multiple-value-bind (form)
  (let ((variables (second form))
        (value-form (third form))
        (body (cdddr form)))
    (when (some 'symbolp variables)
      (return-from cg-multiple-value-bind (cg-form `(error '"TODO: special variable binding (m-v-bind)"))))
    (let ((env-size (count-if (lambda (x) (and (lexical-variable-p x) (not (localp x)))) variables))
          (*environment* *environment*)
          (*environment-chain* *environment-chain*))
      (unless (zerop env-size)
        (push (remove-if 'localp variables) *environment*)
        ;; TODO: Check escaping stuff. My upward funargs D:
        ;; Allocate local environment on the stack.
        (emit `(sys.lap-x86:sub64 :csp ,(* (+ env-size 2 (if (evenp env-size) 0 1)) 8)))
        ;; Default slots to NIL.
        (dotimes (i (1+ env-size))
          (emit `(sys.lap-x86:mov64 (:csp ,(* (1+ i) 8)) nil)))
        ;; Initialize the header. Simple-vector uses tag 0.
        (emit `(sys.lap-x86:mov64 (:csp) ,(ash (1+ env-size) 8))
              ;; Get value.
              `(sys.lap-x86:lea64 :rbx (:csp #b0111)))
        (when *environment-chain*
          ;; Set back-link.
          (emit `(sys.lap-x86:mov64 :r8 (:stack ,(first *environment-chain*)))
                `(sys.lap-x86:mov64 (:rbx 1) :r8)))
        (let ((slot (find-stack-slot)))
          (setf (aref *stack-values* slot) (cons :environment :home))
          (push slot *environment-chain*)
          (emit `(sys.lap-x86:mov64 (:stack ,slot) :rbx))))
      ;; Initialize local variables to NIL.
      (dolist (var variables)
        (cond ((zerop (lexical-variable-use-count var)))
              ((localp var)
               (let ((slot (find-stack-slot)))
                 (setf (aref *stack-values* slot) (cons var :home))
                 (emit `(sys.lap-x86:mov64 (:stack ,slot) nil))))
              (t)))
      ;; Compile the value-form.
      (let ((value-tag (let ((*for-value* :multiple))
                         (cg-form value-form))))
        (load-multiple-values value-tag))
      ;; Bind variables.
      (let* ((jump-targets (mapcar (lambda (x)
                                     (declare (ignore x))
                                     (gensym))
                                   variables))
             (no-vals-label (gensym))
             (var-count (length variables))
             (value-locations (nreverse (subseq '(:r8 :r9 :r10 :r11 :r12) 0 (min 5 var-count)))))
        (dotimes (i (- var-count 5))
          (push i value-locations))
        (emit `(sys.lap-x86:mov64 :rax :rbx))
        (dotimes (i var-count)
          (emit `(sys.lap-x86:cmp64 :rcx ,(fixnum-to-raw (- var-count i)))
                `(sys.lap-x86:jae ,(nth i jump-targets))))
        (emit `(sys.lap-x86:jmp ,no-vals-label))
        (mapc (lambda (var label)
                (emit label)
                (cond ((zerop (lexical-variable-use-count var))
                       (pop value-locations))
                      (t (let ((register (cond ((integerp (first value-locations))
                                                (emit `(sys.lap-x86:mov64 :rbx (:lsp ,(* (pop value-locations) 8))))
                                                :rbx)
                                               (t (pop value-locations)))))
                           (cond ((localp var)
                                  (emit `(sys.lap-x86:mov64 (:stack ,(position (cons var :home)
                                                                               *stack-values*
                                                                               :test 'equal))
                                                            ,register)))
                                 (t (multiple-value-bind (stack-slot depth offset)
                                        (find-var var *environment* *environment-chain*)
                                      (unless (zerop depth)
                                        (return-from cg-multiple-value-bind (cg-form '(error '"TODO: deep non-local lexical variables."))))
                                      (emit `(sys.lap-x86:mov64 :r13 (:stack ,stack-slot))
                                            `(sys.lap-x86:mov64 (:r13 ,(1+ (* (1+ offset) 8))) ,register))
                                      (setf *r8-value* (list (gensym))))))))))
              (reverse variables)
              jump-targets)
        (emit no-vals-label
              `(sys.lap-x86:mov64 :lsp :rax)))
      (cg-form `(progn ,@body)))))

(defun cg-multiple-value-call (form)
  (let ((function (second form))
        (value-forms (cddr form)))
    (cond ((null value-forms)
           ;; Just like a regular call.
           (cg-function-form `(funcall ,function)))
          ((null (cdr value-forms))
           ;; Single value form.
           (let ((fn-tag (let ((*for-value* t)) (cg-form function))))
             (when (not fn-tag)
               (return-from cg-multiple-value-call nil))
             (let ((value-tag (let ((*for-value* :multiple))
                                (cg-form (first value-forms)))))
               (when (not value-tag)
                 (return-from cg-multiple-value-call nil))
               (load-multiple-values value-tag)
               (load-in-reg :r13 fn-tag t)
               (let ((type-error-label (gensym))
                     (function-label (gensym)))
                 (emit-trailer (type-error-label)
                   (raise-type-error :r13 '(or function symbol)))
                 (emit `(sys.lap-x86:mov8 :al :r13l)
                       `(sys.lap-x86:and8 :al #b1111)
                       `(sys.lap-x86:cmp8 :al #b1100)
                       `(sys.lap-x86:je ,function-label)
                       `(sys.lap-x86:cmp8 :al #b0010)
                       `(sys.lap-x86:jne ,type-error-label)
                       `(sys.lap-x86:mov64 :r13 (:symbol-function :r13))
                       function-label
                       `(sys.lap-x86:call :r13)
                       `(sys.lap-x86:mov64 :lsp :rbx)))
               (setf *r8-value* (list (gensym))))))
          (t (cg-function-form `(error '"TODO multiple-value-call with >1 arguments."))))))

(defun cg-multiple-value-prog1 (form)
  (cg-form `(error '"TODO multiple-value-prog1")))

(defun cg-progn (form)
  (if (rest form)
      (do ((i (rest form) (rest i)))
	  ((endp (rest i))
	   (cg-form (first i)))
	(let* ((*for-value* nil)
	       (tag (cg-form (first i))))
	  (when (null tag)
	    (return-from cg-progn 'nil))))
      (cg-form ''nil)))

;;;(defun cg-progv (form))

(defun cg-quote (form)
  form)

(defun cg-return-from (form)
  (let* ((label (assoc (second form) *rename-list*))
	 (*for-value* (third label))
	 (tag (cg-form (third form))))
    (cond ((eql *for-value* :multiple)
           (load-multiple-values tag))
          (*for-value*
           (load-in-r8 tag t)))
    (incf (fourth label))
    (smash-r8)
    (emit `(sys.lap-x86:jmp ,(second label)))
    'nil))

(defun find-variable-home (var)
  (dotimes (i (length *stack-values*)
	    (error "No home for ~S?" var))
    (let ((x (aref *stack-values* i)))
      (when (and (consp x) (eq (car x) var) (eq (cdr x) :home))
	(return i)))))

(defun cg-setq (form)
  (let ((var (second form))
	(val (third form)))
    (cond ((localp var)
           ;; Copy var if there are unsatisfied tags on the load list.
           (dolist (l *load-list*)
             (when (and (consp l) (eq (car l) var))
               ;; Don't save if there is something satisfying this already.
               (multiple-value-bind (loc true-tag)
                   (value-location l)
                 (declare (ignore loc))
                 (unless (tag-saved-on-stack-p true-tag)
                   (load-in-r8 l nil)
                   (smash-r8 t)))))
           (let ((tag (let ((*for-value* t)) (cg-form val)))
                 (home (find-variable-home var)))
             (when (null tag)
               (return-from cg-setq))
             (load-in-r8 tag t)
             (emit `(sys.lap-x86:mov64 (:stack ,home) :r8))
             (setf *r8-value* (cons var :dup))
             (cons var (incf *run-counter* 2))))
          (t (let ((tag (let ((*for-value* t)) (cg-form val))))
               (when (null tag)
                 (return-from cg-setq))
               (multiple-value-bind (stack-slot depth offset)
                   (find-var var *environment* *environment-chain*)
                 (unless (zerop depth)
                   (return-from cg-setq (cg-form '(error '"TODO: deep non-local lexical variables."))))
                 (load-in-r8 tag t)
                 (emit `(sys.lap-x86:mov64 :r9 (:stack ,stack-slot))
                       `(sys.lap-x86:mov64 (:r9 ,(1+ (* (1+ offset) 8))) :r8))
                 (setf *r8-value* (list (gensym)))))))))

(defun tagbody-localp (info)
  (dolist (tag (tagbody-information-go-tags info) t)
    (unless (or (null (go-tag-used-in tag))
		(and (null (cdr (go-tag-used-in tag)))
		     (eq (car (go-tag-used-in tag)) (tagbody-information-definition-point info))))
      (return nil))))

;;; FIXME: Everything must return a valid tag if control flow follows.

(defun cg-tagbody (form)
  (let ((*for-value* nil)
	(stack-slots (set-up-for-branch))
	(*rename-list* *rename-list*)
	(last-value t))
    (when (not (tagbody-localp (second form)))
      (return-from cg-tagbody (cg-form '(error '"TODO: Escaping tagbodies."))))
    ;; Generate labels for each tag.
    (dolist (i (tagbody-information-go-tags (second form)))
      ;(push (list i (gensym (format nil "~S" (go-tag-name i)))) *rename-list*))
      (push (list i (gensym)) *rename-list*))
    (dolist (stmt (cddr form))
      (if (go-tag-p stmt)
	  (progn
	    (smash-r8)
	    (setf *stack-values* (copy-stack-values stack-slots))
	    (setf last-value t)
	    (emit (second (assoc stmt *rename-list*))))
	  (setf last-value (cg-form stmt))))
    (if last-value
	''nil
	'nil)))

(defun cg-the (form)
  (cg-form (third form)))

;;;(defun cg-unwind-protect (form))

(defun fixnump (object)
  (typep object '(signed-byte 61)))

(defun value-location (tag &optional kill)
  (when kill
    (setf *load-list* (delete tag *load-list*)))
  (cond ((eq (car tag) 'quote)
	 (values (if (and (consp *r8-value*)
			  (eq (car *r8-value*) 'quote)
			  (eql (cadr tag) (cadr *r8-value*)))
		     :r8
		     tag)
		 tag))
	((null (cdr tag))
	 (values (if (eq tag *r8-value*)
		     :r8
		     (dotimes (i (length *stack-values*)
			       (error "Cannot find tag ~S." tag))
		       (when (eq tag (aref *stack-values* i))
			 (return (list :stack i)))))
		 tag))
	((lexical-variable-p (car tag))
	 ;; Search for the lowest numbered time that is >= to the tag time.
	 (let ((best (when (and (consp *r8-value*) (eq (car *r8-value*) (car tag))
				(integerp (cdr *r8-value*)) (>= (cdr *r8-value*) (cdr tag)))
		       *r8-value*))
	       (best-loc :r8)
	       (home-loc nil)
	       (home nil))
	   (dotimes (i (length *stack-values*))
	     (let ((val (aref *stack-values* i)))
	       (when (and (consp val) (eq (car val) (car tag)))
		 (cond ((eq (cdr val) :home)
			(setf home (cons (car val) *run-counter*)
			      home-loc (list :stack i)))
		       ((and (integerp (cdr val)) (>= (cdr val) (cdr tag))
			     (or (null best)
				 (< (cdr val) (cdr best))))
			(setf best val
			      best-loc (list :stack i)))))))
	   (values (or (when best
			 best-loc)
		       ;; R8 might hold a duplicate (thanks to let or setq), use that instead of home.
		       (when (and *r8-value* (consp *r8-value*) (eq (car *r8-value*) (car tag)) (eq (cdr *r8-value*) :dup))
			 :r8)
		       home-loc
		       (error "Cannot find tag ~S." tag))
		   (or best
		       (when (and *r8-value* (consp *r8-value*) (eq (car *r8-value*) (car tag)) (eq (cdr *r8-value*) :dup))
			 *r8-value*)
		       home))))
	(t (error "What kind of tag is this? ~S" tag))))

(defun condemed-p (tag)
  (cond ((eq (cdr tag) :home)
	 nil)
	((eq (cdr tag) :dup)
	 t)
	(t (dolist (v *load-list* t)
	     (when (eq (first tag) (first v))
	       (if (null (rest tag))
		   (return nil)
		   ;; Figure out the best tag that satisfies this load.
		   (let ((best (when (and (consp *r8-value*) (eq (car *r8-value*) (car tag))
					  (integerp (cdr *r8-value*)) (>= (cdr *r8-value*) (cdr tag)))
				 *r8-value*)))
		     (dotimes (i (length *stack-values*))
		       (let ((val (aref *stack-values* i)))
			 (when (and (consp val) (eq (car val) (car v))
				    (integerp (cdr val)) (>= (cdr val) (cdr v))
				    (or (null best)
					(< (cdr val) (cdr best))))
			   (setf best val))))
		     (when (eq best tag)
		       (return nil)))))))))

(defun find-stack-slot ()
  ;; Find a free stack slot, or allocate a new one.
  (dotimes (i (length *stack-values*)
	    (vector-push-extend nil *stack-values*))
    (when (or (null (aref *stack-values* i))
	      (condemed-p (aref *stack-values* i)))
      (setf (aref *stack-values* i) nil)
      (return i))))

(defun smash-r8 (&optional do-not-kill-r8)
  "Check if the value in R8 is on the load-list and flush it to the stack if it is."
  ;; Avoid flushing if it's already on the stack.
  (when (and *r8-value*
             (not (eql *r8-value* :multiple))
	     (not (condemed-p *r8-value*))
	     (not (tag-saved-on-stack-p *r8-value*)))
    (let ((slot (find-stack-slot)))
      (setf (aref *stack-values* slot) *r8-value*)
      (emit `(sys.lap-x86:mov64 (:stack ,slot) :r8))))
  (unless do-not-kill-r8
    (setf *r8-value* nil)))

(defun load-constant (register value)
  (cond ((eql value 0)
	 (emit `(sys.lap-x86:xor64 ,register ,register)))
	((eq value 'nil)
	 (emit `(sys.lap-x86:mov64 ,register nil)))
	((eq value 't)
	 (emit `(sys.lap-x86:mov64 ,register t)))
	((fixnump value)
	 (emit `(sys.lap-x86:mov64 ,register ,(fixnum-to-raw value))))
	((characterp value)
	 (emit `(sys.lap-x86:mov64 ,register ,(character-to-raw value))))
	(t (emit `(sys.lap-x86:mov64 ,register (:constant ,value))))))

(defun load-multiple-values (tag)
  (cond ((eql tag :multiple))
        (t (load-in-r8 tag t)
           (emit `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 1))
                 `(sys.lap-x86:mov64 :rbx :lsp)))))

(defun load-in-r8 (tag &optional kill)
  (multiple-value-bind (loc true-tag)
      (value-location tag nil)
    (unless (eq loc :r8)
      (smash-r8)
      (ecase (first loc)
	((quote) (load-constant :r8 (second loc)))
	((:stack) (emit `(sys.lap-x86:mov64 :r8 (:stack ,(second loc))))))
      (setf *r8-value* true-tag))
    (when kill
      (setf *load-list* (delete tag *load-list*)))))

(defun load-in-reg (reg tag &optional kill)
  (if (eql reg :r8)
      (load-in-r8 tag kill)
      (let ((loc (value-location tag nil)))
	(unless (eql loc reg)
	  (if (eql loc :r8)
	      (emit `(sys.lap-x86:mov64 ,reg :r8))
	      (ecase (first loc)
		((quote) (load-constant reg (second loc)))
		((:stack) (emit `(sys.lap-x86:mov64 ,reg (:stack ,(second loc))))))))
	(when kill
	  (setf *load-list* (delete tag *load-list*))))))

(defun prep-arguments-for-call (arg-forms)
  (when arg-forms
    (let ((args '())
	  (arg-count 0))
      (let ((*for-value* t))
	(dolist (f arg-forms)
	  (push (cg-form f) args)
	  (incf arg-count)
	  (when (null (first args))
	    ;; Non-local control transfer, don't actually need those results now.
	    (dolist (i (rest args))
	      (setf *load-list* (delete i *load-list*)))
	    (return-from prep-arguments-for-call nil))))
      (setf args (nreverse args))
      ;; Interrupts are not a problem here.
      ;; They switch stack groups and don't touch the Lisp stack.
      (let ((stack-count (- arg-count 5)))
	(when (plusp stack-count)
	  ;; Clear the new stack slots.
	  (dotimes (i stack-count)
	    (emit `(sys.lap-x86:mov64 (:lsp ,(- (* (1+ i) 8))) nil)))
	  ;; Adjust the stack.
	  (emit `(sys.lap-x86:sub64 :lsp ,(* stack-count 8)))
	  ;; Load values on the stack.
	  ;; Use r13 here to preserve whatever is in r8.
	  (do ((i 0 (1+ i))
	       (j (nthcdr 5 args) (cdr j)))
	      ((null j))
	    (load-in-reg :r13 (car j) t)
	    (emit `(sys.lap-x86:mov64 (:lsp ,(* i 8)) :r13)))))
      ;; Load other values in registers.
      (when (> arg-count 4)
	(load-in-reg :r12 (nth 4 args) t))
      (when (> arg-count 3)
	(load-in-reg :r11 (nth 3 args) t))
      (when (> arg-count 2)
	(load-in-reg :r10 (nth 2 args) t))
      (when (> arg-count 1)
	(load-in-reg :r9 (nth 1 args) t))
      (when (> arg-count 0)
	(load-in-r8 (nth 0 args) t))))
  t)

;; Compile a VALUES form.
(defun cg-values (forms)
  (cond ((null forms)
         ;; No values.
         (cond ((eql *for-value* :multiple)
                ;; R8 must hold NIL.
                (load-in-r8 ''nil)
                (emit `(sys.lap-x86:xor32 :ecx :ecx)
                      `(sys.lap-x86:mov64 :rbx :lsp))
                :multiple)
               (t (cg-form ''nil))))
        ((null (rest forms))
         ;; Single value.
         (let ((*for-value* t))
           (cg-form (first forms))))
        (t ;; Multiple-values
         (cond ((eql *for-value* :multiple)
                ;; The MV return convention happens to be almost identical
                ;; to the standard calling convention!
                (when (prep-arguments-for-call forms)
                  (load-constant :rcx (length forms))
                  (let ((stack-count (- (length forms) 5)))
                    (cond ((> stack-count 0)
                           (emit `(sys.lap-x86:lea64 :rbx (:lsp ,(* stack-count 8)))))
                          (t (emit `(sys.lap-x86:mov64 :rbx :lsp)))))
                  :multiple))
               (t ;; VALUES behaves like PROG1 when not compiling for multiple values.
                (let ((tag (cg-form (first forms))))
                  (unless tag (return-from cg-values nil))
                  (let ((*for-value* nil))
                    (dolist (f (rest forms))
                      (when (not (cg-form f))
                        (setf *load-list* (delete tag *load-list*))
                        (return-from cg-values nil))))
                  tag))))))

(defun cg-function-form (form)
  (let ((fn (when (not *suppress-builtins*)
              (match-builtin (first form) (length (rest form))))))
    (cond ((and (eql *for-value* :predicate)
                (or (eql (first form) 'null)
                    (eql (first form) 'not))
                (= (length form) 2))
           (let* ((tag (cg-form (second form)))
                  (loc (when (and tag (not (keywordp tag)))
                         (value-location tag t))))
             (cond ((null tag) nil)
                   ((keywordp tag)
                    ;; Invert the sense.
                    (invert-predicate tag))
                   ;; Perform (eql nil ...).
                   ((and (consp loc) (eq (first loc) :stack))
                    (emit `(sys.lap-x86:cmp64 (:stack ,(second loc)) nil))
                    :e)
                   (t (load-in-r8 tag)
                      (emit `(sys.lap-x86:cmp64 :r8 nil))
                      :e))))
          (fn
	   (let ((args '()))
	     (let ((*for-value* t))
	       (dolist (f (rest form))
		 (push (cg-form f) args)
		 (when (null (first args))
		   ;; Non-local control transfer, don't actually need those results now.
		   (dolist (i (rest args))
		     (setf *load-list* (delete i *load-list*)))
		   (return-from cg-function-form nil))))
	     (apply fn (nreverse args))))
	  ((and (eql (first form) 'funcall)
		(rest form))
	   (let* ((*for-value* t)
		  (fn-tag (cg-form (second form)))
		  (type-error-label (gensym))
		  (function-label (gensym))
                  (out-label (gensym)))
	     (cond ((prep-arguments-for-call (cddr form))
		    (emit-trailer (type-error-label)
		      (raise-type-error :r13 '(or function symbol)))
		    (load-in-reg :r13 fn-tag t)
		    (smash-r8)
		    (load-constant :rcx (length (cddr form)))
		    (emit `(sys.lap-x86:mov8 :al :r13l)
			  `(sys.lap-x86:and8 :al #b1111)
			  `(sys.lap-x86:cmp8 :al #b1100)
			  `(sys.lap-x86:je ,function-label)
			  `(sys.lap-x86:cmp8 :al #b0010)
			  `(sys.lap-x86:jne ,type-error-label)
			  `(sys.lap-x86:call (:symbol-function :r13))
                          `(sys.lap-x86:jmp ,out-label)
			  function-label
			  `(sys.lap-x86:call :r13)
                          out-label)
                    (cond ((eql *for-value* :multiple)
                           :multiple)
                          (t (emit `(sys.lap-x86:mov64 :lsp :rbx))
                             (setf *r8-value* (list (gensym))))))
		   (t ;; Flush the unused function.
		    (setf *load-list* (delete fn-tag *load-list*))))))
          ((eql (first form) 'values)
           (cg-values (rest form)))
	  (t (when (prep-arguments-for-call (rest form))
	       (load-constant :r13 (first form))
	       (smash-r8)
	       (load-constant :rcx (length (rest form)))
	       (emit `(sys.lap-x86:call (:symbol-function :r13)))
               (cond ((eql *for-value* :multiple)
                      :multiple)
                     (t (emit `(sys.lap-x86:mov64 :lsp :rbx))
                        (setf *r8-value* (list (gensym))))))))))

;;; Locate a variable in the environment.
(defun find-var (var env chain)
  (assert chain (var env chain) "No environment chain?")
  (assert env (var env chain) "No environment?")
  (cond ((member var (first env))
         (values (first chain) 0 (position var (first env))))
        ((rest chain)
         (find-var var (rest env) (rest chain)))
        (t ;; Walk the environment using the current chain as a root.
         (let ((depth 0))
           (dolist (e (rest env)
                    (error "~S not found in environment?" var))
             (incf depth)
             (when (member var e)
               (return (values (first chain) depth
                               (position var e)))))))))

(defun cg-variable (form)
  (cond
    ((localp form)
     (cons form (incf *run-counter*)))
    (t ;; Non-local variable, requires an environment lookup.
     (multiple-value-bind (stack-slot depth offset)
         (find-var form *environment* *environment-chain*)
       (unless (zerop depth)
         (return-from cg-variable (cg-form '(error '"TODO: deep non-local lexical variables."))))
       (smash-r8)
       (emit `(sys.lap-x86:mov64 :r8 (:stack ,stack-slot))
             `(sys.lap-x86:mov64 :r8 (:r8 ,(1+ (* (1+ offset) 8)))))
       (setf *r8-value* (list (gensym)))))))

(defun cg-lambda (form)
  (let ((lap-code (codegen-lambda form)))
    (cond (*environment*
           ;; Generate a closure on the stack.
           ;; FIXME: Escape analysis.
           (smash-r8)
           (emit `(sys.lap-x86:sub64 :csp ,(* 6 8))
                 ;; Fill using 32-bit writes.
                 ;; There are no mem64,imm64 instructions.
                 `(sys.lap-x86:mov32 (:csp  0) #x00020001)
                 `(sys.lap-x86:mov32 (:csp  4) #x00000002)
                 `(sys.lap-x86:mov32 (:csp  8) #x00000000)
                 `(sys.lap-x86:mov32 (:csp 12) #x151D8948)
                 `(sys.lap-x86:mov32 (:csp 16) #xFF000000)
                 `(sys.lap-x86:mov32 (:csp 20) #x00000725)
                 `(sys.lap-x86:mov32 (:csp 24) #xCCCCCC00)
                 `(sys.lap-x86:mov32 (:csp 28) #xCCCCCCCC)
                 ;; Zero out constant pool.
                 `(sys.lap-x86:mov32 (:csp 32) 0)
                 `(sys.lap-x86:mov32 (:csp 36) 0)
                 `(sys.lap-x86:mov32 (:csp 40) 0)
                 `(sys.lap-x86:mov32 (:csp 44) 0)
                 ;; Produce closure object.
                 `(sys.lap-x86:lea64 :r8 (:csp 12))
                 ;; Fill constant pool.
                 `(sys.lap-x86:mov64 :r9 (:constant ,lap-code))
                 `(sys.lap-x86:mov64 (:r8 ,(+ 32 -12)) :r9)
                 `(sys.lap-x86:mov64 :r9 (:stack ,(first *environment-chain*)))
                 `(sys.lap-x86:mov64 (:r8 ,(+ 40 -12)) :r9))
           (setf *r8-value* (list (gensym))))
          (t (list 'quote lap-code)))))

(defun raise-type-error (reg typespec)
  (unless (eql reg :r8)
    (emit `(sys.lap-x86:mov64 :r8 ,reg)))
  (load-constant :r9 typespec)
  (load-constant :r13 'sys.int::raise-type-error)
  (emit `(sys.lap-x86:mov32 :ecx ,(fixnum-to-raw 2))
	`(sys.lap-x86:call (:symbol-function :r13))
	`(sys.lap-x86:ud2))
  nil)

(defun fixnum-check (reg &optional (typespec 'fixnum))
  (let ((type-error-label (gensym)))
    (emit-trailer (type-error-label)
      (raise-type-error reg typespec))
    (emit `(sys.lap-x86:test64 ,reg #b111)
	  `(sys.lap-x86:jnz ,type-error-label))))
