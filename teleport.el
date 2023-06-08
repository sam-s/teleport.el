;; teleport.el --- tramp backend for teleport (goteleport.com) -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2023 Caramel Hooves
;;
;; Author: Caramel Hooves <caramel.hooves@protonmail.com>
;; Maintainer: Caramel Hooves <caramel.hooves@protonmail.com>
;; Created: March 18, 2023
;; Modified: March 19, 2023
;; Version: 0.0.1
;; Keywords: tools
;; Homepage: https://github.com/caramelhooves/teleport.el
;; Package-Requires: ((emacs "27.1"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Code:

(require 'tramp)
(define-widget 'teleport-list-filed-config 'lazy
  "Configuration for a single column in the teleport node list buffer"
  :offset 4
  :tag "Column"
  :type '(group :tag "Properties"
          (const :format "" :value :name)
          (string :tag "Name" :value "")
          (const :format "" :value :path)
          (repeat :tag "Path" (string))
          (set :inline t :tag "Optional properties"
               (list :inline t :format "%v"
                     (const :format "" :value :width)
                     (integer :tag "Custom Width"))
               (const :tag "Hide" :inline t :value (:hidden t)))))

(defcustom teleport-list-nodes-fields nil
  "Columns to display in the teleport node list buffer"
  :group 'teleport
  :type '(repeat teleport-list-filed-config))


(defcustom teleport-list-nodes-fields-width 20
  "Default width of each column in the teleport list buffer"
  :group 'teleport
  :type 'integer)

(defcustom teleport-list-nodes-buffer-name "*Teleport Nodes List*"
  "Name of the teleport node list buffer"
  :group 'teleport
  :type 'string)

(defcustom teleport-login-prompts
  '(("If browser window does not open automatically, open it by clicking on the link.*"
     .
     teleport--display-current-buffer)
    (".*Password: " . teleport--read-password))
  "Alist of patterns and functions to handle them. If the pattern
is match in stderr output of tsh, the matching function is
called"
  :group 'teleport
  :type '(alist :key-type regex :value-type function))

(defcustom teleport-list-nodes-show-hostname nil
  "Show node's hostname in the list"
  :type 'boolean
  :group 'teleport
  )

(defcustom teleport-list-nodes-hostname-column ".hostname"
  "Column name to display node's hostname, should be unique and not
overlap with any existing cmd_labels."
  :type 'string)

(defconst teleport-tramp-method "tsh"
  "Tramp method for teleport.")

(defvar-local teleport-list-nodes--current-directory nil)

;;;###autoload
(defun teleport-tramp-add-method ()
  "Add teleport tramp method."
  (add-to-list
   'tramp-methods
   `("tsh"
     (tramp-login-program "tsh")
     (tramp-direct-async t)
     (tramp-login-args (("ssh") ("-l" "%u") ("%h")))
     (tramp-copy-args (("scp" "-r")))
     (tramp-copy-recursive t)
     (tramp-remote-shell "/bin/sh")
     (tramp-remote-shell-args ("-i" "-c"))))
  (tramp-set-completion-function
     teleport-tramp-method '((teleport-tramp-completion ""))))

(defun teleport--tsh-sentinel (process event)
  "Sentinel for caching tsh commands output process. Stores JSON
parsed output in `(process-set process :output-json-symbol)'"
  ;;TODO handle errors as described in the docs
  ;;(info "elisp#Accepting Output")
  (with-current-buffer (process-buffer process)
    (cond
     ((string= event "finished\n")
      (goto-char (point-min))
      (let ( ;; A symbol to store the cache
            (output-symbol (process-get process :output-json-symbol))
            ;; function to call to update the buffer
            (completion-notification
             (process-get process :completion-notification)))

        (set output-symbol (json-parse-buffer))
        (kill-buffer (current-buffer))
        (funcall completion-notification)))
     (t
      (message "Teleport status process failed: %s, %s, stderr: %s"
               event
               (buffer-string)
               (with-current-buffer (process-get process :stderr-buffer) (buffer-string))
               )))))

(defun teleport--display-current-buffer (&rest _)
  "Show current buffer in a new window"
  (display-buffer (current-buffer)))

(defun teleport--read-password (tsh-process)
  "Read password from minibuffer"
  (process-send-string
   tsh-process (format "%s\n" (read-passwd (buffer-string)))))

(defun teleport--tsh-stderr-filter (process output)
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert output)
    (goto-char (point-min))
    (dolist (prompt teleport-login-prompts)
      (when (re-search-forward (car prompt) nil t)
        (funcall (cdr prompt) (process-get process :main-process))))))

(defun teleport--tsh-stderr-sentinel (process event)
  (with-current-buffer (process-buffer process)
    (cond
     ((string= event "finished\n")
      (delete-windows-on (current-buffer) 't)
      (kill-buffer))
     (t
      (message "Teleport stderr helper process failed: %s, %s"
               event
               (buffer-string))))))

(defun teleport--tsh-cmd-async
    (output-json-symbol
     process-symbol completion-notification &rest cmd)
  "Start 'cmd' asynchronously and stores the output in `output-symbol'."
  (let ((output-buffer (generate-new-buffer "*tsh-cmd-async*" t))
        (stderr-process
         (make-pipe-process
          :name "tsh-cmd-async-stderr-process"
          :buffer
          (generate-new-buffer "*tsh-cmd-async-stderr*")
          :filter #'teleport--tsh-stderr-filter
          :sentinel #'teleport--tsh-stderr-sentinel)))
    (let ((process
           (make-process
            :name (symbol-name process-symbol)
            :buffer output-buffer
            :command cmd
            :sentinel #'teleport--tsh-sentinel
            :connection-type 'pipe
            :stderr stderr-process
            :noquery t)))
      (process-put process :output-json-symbol output-json-symbol)
      (process-put process :completion-notification completion-notification)
      (process-put process :stderr-buffer (process-buffer stderr-process))
      (process-put stderr-process :main-process process)
      (set process-symbol process))))

(defun teleport--tsh-cmd-async-cached (output-json-symbol process-symbol completion-notification &rest cmd)
  "Start 'cmd' asynchronously if `process-symbol' process is not
running. Store the result in `output-json-symbol'."

  (unless completion-notification
    (setq completion-notification
          (lambda () (message "Teleport cmd done: %s" cmd))))

  (let ((old-proc (symbol-value process-symbol)))
    ;; If the process is *not* running, start the async command
    (unless (process-live-p old-proc)
      (apply #'teleport--tsh-cmd-async
             output-json-symbol
             process-symbol
             completion-notification
             cmd)))
  (symbol-value output-json-symbol))

(defvar teleport--nodes-async-cache []
  "Cached vector of teleport nodes")

(defvar teleport--nodes-async-process nil
  "Background process for async completion")

(defun teleport--get-nodes-async-cached
    (&optional completion-notification)
  "Returns cached list of teleport nodes"
  (teleport--tsh-cmd-async-cached 'teleport--nodes-async-cache
                                  'teleport--nodes-async-process
                                  completion-notification
                                  "tsh"
                                  "ls"
                                  "-f"
                                  "json"))

(defvar teleport--logins-async-cache '(nil)
  "Cached hashtable of available teleport nodes")

(defvar teleport--logins-async-process nil
  "Background process for async completion")

(defun teleport--status-completion-async-cached
    (&optional completion-notification)
  "Returns cached list of logins available"
  (teleport--tsh-cmd-async-cached 'teleport--logins-async-cache
                                  'teleport--logins-async-process
                                  completion-notification
                                  "tsh"
                                  "status"
                                  "-f"
                                  "json"))

(defconst teleport--internal-join-login "-teleport-internal-join"
  "Teleport login used to observe an existing session, it is
  filtered out from the list of available logins")

(defun teleport--get-logins (status)
  "Returns a list of logins from the status output"
  (when status
    (let ((logins (gethash "logins" (gethash "active" status))))
      (seq-remove
       (lambda (login)
         (string= teleport--internal-join-login login))
       logins))))

(defun teleport-tramp-completion (&optional _)
  "Return list of tramp completion. The function runs
asynchronously and returns cached results."
  (let* ((nodes (teleport--get-nodes-async-cached))
         (status (teleport--status-completion-async-cached))
         (logins (teleport--get-logins status)))
    (cl-loop
     for host across nodes
     for host-name = (gethash "name" (gethash "metadata" host))
     append (mapcar (lambda (login) (list login host-name)) logins))))


(defun teleport--completion-annotation-all-fields
    (metadata &optional prefix)
  "Format an annotation string by printing all fields in METADATA."
  (cl-loop
   for key being the hash-key of metadata
   for value =(gethash key metadata)
   if (hash-table-p value)
   concat (teleport--completion-annotation-all-fields value
                                               (concat
                                                prefix key "."))
   else
   concat
   (format "%s%s: %s, " prefix key value)))

(defun teleport--completion-format-field (fieldnames metadata)
  "Format a field from METADATA. if the field is nil, return an empty string"
  (let ((val (--reduce-from (gethash it acc) metadata fieldnames)))
    (if (or (null val) (string= val ""))
        ""
      (format "%s: %s" (string-join fieldnames ".") val))))


(defun teleport--completion-annotation-minimal (metadata &rest _)
  "Format an annotation string, print only the most important fields."
  (let* ((fields
          (list
           (teleport--completion-format-field '("addr") metadata)
           (teleport--completion-format-field
            '("hostname") metadata)))
         (cmd_labels_metadata (gethash "cmd_labels" metadata))
         (cmd_labels
          (--map
           (format "%s: %s"
                   it
                   (gethash
                    "result" (gethash it cmd_labels_metadata)))
           (hash-table-keys cmd_labels_metadata))))
    (string-join (-remove #'string-empty-p (nconc fields cmd_labels))
                 ", ")))

(defun teleport--seq-last (sequence)
  "Return the last element of SEQUENCE."
  ;; I wonder why it is not implemented in `seq'
  (seq-elt sequence (- (length sequence) 1)))

(defun teleport-list-nodes--column-name ()
  (or
   (get-text-property (point) 'tabulated-list-column-name)
   (car (teleport--seq-last tabulated-list-format))))

(defun teleport-list-nodes-mode--kill-column ()
  "Hide the column at point"
  (interactive)
  (let ((col (cl-find
   (teleport-list-nodes--column-name)
   teleport-list-nodes-fields
   :key (lambda (x) (plist-get x :name)))))
    (message "Hide column %s" col)
    (plist-put col :hidden t))
  (teleport-list--refresh-buffer))

(defun teleport-mode--filter-by-pattern (pattern)
  (interactive (list (read-regexp "Filter by regexp")))
  (let* ((col-name (teleport-list-nodes--column-name))
         (col-index
          (cl-position col-name tabulated-list-format
                       :key #'car
                       :test #'string=)))
    (setq tabulated-list-entries
          (cl-remove-if-not
           (lambda (x) (string-match pattern x))
           tabulated-list-entries
           :key (lambda (x) (elt (cadr x) col-index)))))
  (tabulated-list-print t))

(defun teleport-list-nodes--get-list-of-unique-cmd-labels (nodes)
  (cl-loop
   for node across nodes
   for spec = (gethash "spec" node)
   for cmd_labels = (gethash "cmd_labels" spec)
   when cmd_labels
   for cmd-labels-path = (hash-table-keys cmd_labels) then (cl-union cmd-labels-path (hash-table-keys cmd_labels) :test #'equal)
   finally return (mapcar (lambda (label)
                            `(,label
                              ("cmd_labels" ,label "result")))
                          cmd-labels-path)))

(defun teleport--refresh-available-spec (nodes)
  "Iterate over NODES and collect all unique cmd_labels names. Stores them in `teleport-list-nodes-fields'"
  ;; Collect all available cmd_labels path from spec. `cmd-labels-path' is a list
  ;; of (label . path), where path is a list of strings showing full path in
  ;; node's JSON
  (let* ((cmd-labels-path (teleport-list-nodes--get-list-of-unique-cmd-labels nodes))
         (all-specs-path
          (if teleport-list-nodes-show-hostname
              ;;FIXME: what if cmd_labels also have 'hostname'? tabulated mode
              ;;does not expect duplicate column names.
              (cons '("hostname" ("hostname")) cmd-labels-path)
            cmd-labels-path)))

      ;; Find which specs are missing from `teleport-list-nodes-fields', compare only 'path' field
      (let ((missing-specs
             (cl-set-difference
              all-specs-path
              (mapcar (lambda (x) (list (plist-get x :name) (plist-get x :path))) teleport-list-nodes-fields)
              :test #'equal
              :key #'cadr)))
      ;; Add them to the `teleport-list-nodes-fields' with default width `teleport-list-nodes-fields-width'
        (setq teleport-list-nodes-fields
              (nconc teleport-list-nodes-fields
                     (mapcar (lambda (x) `(:name ,(car x) :path ,(cadr x)))
                             missing-specs))))))

(defun teleport-list--calculate-list-format (nodes-fields)
  "Calculate a vector suitable for `tabulated-list-format' from NODES-FIELDS(
`teleport-list-nodes-fields')"
  (let ((enabled-fields
         (seq-filter (lambda (x) (not (plist-get x :hidden))) nodes-fields)))
  (apply #'vector (mapcar (lambda (x) (list
                                       (plist-get x :name)
                                       (or (plist-get x :width) teleport-list-nodes-fields-width)
                                       t)) enabled-fields))))

(defun teleport-list--refresh-buffer ()
  (interactive)
  (with-current-buffer (get-buffer-create
                        teleport-list-nodes-buffer-name)
    (teleport--refresh-available-spec teleport--nodes-async-cache)
    (setq tabulated-list-format
          (teleport-list--calculate-list-format
           teleport-list-nodes-fields))

    (setq tabulated-list-entries
          (teleport-list--nodes-mode-entries
           teleport--nodes-async-cache
           teleport-list-nodes-fields))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (teleport-list--update-modeline)))

(defun teleport-list-nodes-mode--update-list ()
  "Fetch the list of teleport nodes and refresh the buffer."
  (interactive)
  (teleport--get-nodes-async-cached #'teleport-list--refresh-buffer)
  (teleport-list--update-modeline))

(defun teleport-list-nodes-mode--reset-columns ()
  "Remove any customization of the displayed columns and re-fill
them with columns from the currently available nodes."
  (interactive)
  (setq teleport-list-nodes-fields nil)
  (teleport--refresh-available-spec teleport--nodes-async-cache)
  (setq tabulated-list-format
        (teleport-list--calculate-list-format
         teleport-list-nodes-fields))
  (teleport-list--refresh-buffer))

(defvar teleport-list-nodes-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "k" 'teleport-list-nodes-mode--kill-column)
    (define-key map "g" 'teleport-list--refresh-buffer)
    (define-key map "G" 'teleport-list-nodes-mode--update-list)
    (define-key map "r" 'teleport-list-nodes-mode--reset-columns)
    (define-key map (kbd "/ p") 'teleport-mode--filter-by-pattern)
    map))

(defun teleport--get-hash-map-nested (map &rest keys)
  "Get nested value from VECTOR by KEYS"
  (cl-loop
   for result = map then (gethash key result)
   for key in keys
   while result
   finally return result))

(defun teleport-list--get-node-label (spec prop-path)
  "Get property by PROP-PATH from node's SPEC. Return empty string if
no such property exist."
  (or (apply #'teleport--get-hash-map-nested spec prop-path) ""))

(defun teleport-list--nodes-mode-entries (nodes list-format)
  (cl-loop
   for node across nodes
   for spec = (gethash "spec" node)
   for name = (gethash "name" (gethash "metadata" node))
   collect (list
            name
            (apply
             #'vector
            (cl-loop
             for p in list-format
             unless (plist-get p :hidden)
             collect (teleport-list--get-node-label spec (plist-get p :path)))))))

(defun teleport-list--update-modeline ()
  (setq mode-line-process
        (format "%s%s"
                (if (process-live-p teleport--nodes-async-process)
                    ":Nodes"
                  "")
                (if (process-live-p teleport--logins-async-cache)
                    ":Logins"
                  "")))
  (force-mode-line-update t))

(defun teleport-list-nodes--set-default-directory ()
  "Set the default directory to point on the remote node."
  (let (switch-default-directory)
    (map-keymap-internal (lambda (event function)
                           (when (eq this-command function)
                             (setq switch-default-directory t)))
                         teleport-list-nodes-mode-map)
    (when switch-default-directory
      (setq-local default-directory
                  (format "/%s:root@%s:"
                          teleport-tramp-method
                          (tabulated-list-get-id))))))


(defun teleport-list-nodes--restore-default-directory ()
  "Restore the default directory to the one used to open nodes list."
  (setq-local default-directory
              teleport-list-nodes--current-directory))

(define-derived-mode
  teleport-list-nodes-mode
  tabulated-list-mode
  "Teleport Nodes"
  "Major mode for listing the available teleport nodes.
\\<teleport-list-nodes-mode-map>
\\{teleport-list-nodes-mode-map}"
  :group 'teleport

  (setq-local teleport-list-nodes--current-directory default-directory)
  (add-hook 'pre-command-hook #'teleport-list-nodes--set-default-directory 90 t)
  (add-hook 'post-command-hook #'teleport-list-nodes--restore-default-directory -90 t)
  (teleport-list--refresh-buffer)
  (teleport--get-nodes-async-cached #'teleport-list--refresh-buffer))

;;;###autoload
(defun teleport-list-nodes ()
  "List all teleport nodes."
  (interactive)
  (switch-to-buffer teleport-list-nodes-buffer-name)
  (teleport-list-nodes-mode))

(provide 'teleport)
;;; teleport.el ends here
