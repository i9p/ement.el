;;; ement-crypto.el --- E2EE support for Ement          -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Free Software Foundation, Inc.

;; Author: Gemini CLI
;; Keywords: comm

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ement-lib)
(require 'ement-structs)

(defcustom ement-crypto-worker-path (expand-file-name "ement-crypto-worker.py" (file-name-directory (or load-file-name (buffer-file-name))))
  "Path to the Ement crypto worker script."
  :type 'file
  :group 'ement)

(defcustom ement-crypto-storage-dir (expand-file-name "crypto" ement-sessions-file)
  "Directory to store crypto keys."
  :type 'directory
  :group 'ement)

(cl-defstruct ement-crypto
  process
  (requests (make-hash-table :test #'equal))
  (next-id 1))

(defun ement-crypto-get (session)
  "Get or initialize the crypto state for SESSION."
  (or (ement-session-crypto session)
      (setf (ement-session-crypto session) (ement-crypto-init session))))

(defun ement-crypto-init (session)
  "Initialize the crypto worker for SESSION."
  (let* ((storage-dir (expand-file-name (ement-user-id (ement-session-user session)) ement-crypto-storage-dir))
         (process (make-process
                   :name (format "ement-crypto-%s" (ement-user-id (ement-session-user session)))
                   :buffer (format " *ement-crypto-%s*" (ement-user-id (ement-session-user session)))
                   :command (list "python3" ement-crypto-worker-path storage-dir)
                   :filter #'ement-crypto-filter
                   :sentinel #'ement-crypto-sentinel
                   :noquery t))
         (crypto (make-ement-crypto :process process)))
    (process-put process :crypto crypto)
    crypto))

(defun ement-crypto-filter (process string)
  "Handle output from the crypto worker PROCESS."
  (let ((crypto (process-get process :crypto))
        (start 0))
    (while (string-match "\n" string start)
      (let* ((line (substring string start (match-beginning 0)))
             (json (ignore-errors (json-read-from-string line)))
             (id (alist-get 'id json))
             (callback (gethash id (ement-crypto-requests crypto))))
        (when callback
          (remhash id (ement-crypto-requests crypto))
          (funcall callback (alist-get 'result json)))
        (setq start (match-end 0))))))

(defun ement-crypto-sentinel (process event)
  "Handle sentinel for crypto worker PROCESS."
  (ement-debug "Crypto worker %s: %s" process event))

(defun ement-crypto-command (session command args callback)
  "Send COMMAND with ARGS to the crypto worker for SESSION.
CALLBACK is called with the result."
  (let* ((crypto (ement-crypto-get session))
         (id (cl-incf (ement-crypto-next-id crypto)))
         (request (list (cons 'id id)
                        (cons 'command command)
                        (cons 'args args))))
    (puthash id callback (ement-crypto-requests crypto))
    (process-send-string (ement-crypto-process crypto)
                         (concat (json-encode request) "\n"))))

(provide 'ement-crypto)

;;; ement-crypto.el ends here
