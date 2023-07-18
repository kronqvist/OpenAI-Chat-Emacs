;;; -*- lexical-binding: t -*-

(require 'request)
(require 'json)
(require 'org-id)

(defvar openai-chat-api-endpoint "https://api.openai.com/v1/chat/completions"
  "The endpoint for the OpenAI API.")

(defvar-local openai-chat-model "gpt-3.5-turbo"
  "The default model being used for the chat.")

(defvar openai-chat--buffer-number 0
  "Keep track of the number of open chat buffers.")

(defvar-local openai-chat--buffer nil
  "Stores the name of the buffer.")

(defface openai-chat--system-face
  '((t :inherit font-lock-comment-face))
  "Face for the system's messages.")

(defface openai-chat--assistant-face
  '((t :inherit font-lock-function-name-face))
  "Face for the assistant's messages.")

(defface openai-chat--user-face
  '((t :inherit font-lock-variable-name-face))
  "Face for the user's messages.")

(defvar openai-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c RET") 'openai-chat-send)
    (define-key map (kbd "C-c C-n") 'openai-chat-set-model)
    (define-key map (kbd "C-c C-e") 'openai-chat-set-api-endpoint)
    map)
  "Keymap for openai-chat-mode.")

(define-derived-mode openai-chat-mode text-mode "ChatGPT"
  "Major mode for talking to OpenAI's chat API."
  (add-hook 'after-change-functions 'openai-chat--buffer-change-hook nil t)
  (setq mode-line-format
        (list "%e" mode-line-front-space
              "OpenAI chat API (" 'openai-chat-model ") "
              mode-line-buffer-identification " "
              mode-line-position)))

(define-derived-mode openai-chat-mode text-mode "OpenAI chat API"
  "Major mode for talking to OpenAI's chat API."
  (add-hook 'after-change-functions 'openai-chat--buffer-change-hook nil t)
  (setq mode-line-format
        (list "%e" mode-line-front-space
              "OpenAI chat API (" 'openai-chat-api-endpoint ", " 'openai-chat-model ") "
              mode-line-buffer-identification " "
              mode-line-position)))

(defun openai-chat-start ()
  "Start a new chat with OpenAI's chat API."
  (interactive)
  (setq openai-chat--buffer-number (1+ openai-chat--buffer-number))  ;; increment buffer number
  (let* ((buffer (get-buffer-create (format "*openai-chat-%s*" openai-chat--buffer-number))))
    (with-current-buffer buffer
      (openai-chat-mode)
      (setq openai-chat-model (openai-chat--load-model))
      (setq openai-chat-api-endpoint (openai-chat--load-api-endpoint))
      (setq openai-chat--buffer (buffer-name buffer))
      (insert "system: You are a helpful assistant\nuser: ")
      (goto-char (point-max)))
    (switch-to-buffer buffer)))

(defun openai-chat--debug (message &rest args)
  "Prints debug message if `OPENAI_CHAT_EMACS_DEBUG` environment variable is set."
  (when (getenv "OPENAI_CHAT_EMACS_DEBUG")
    (apply 'message (concat "DEBUG: " message) args)))

(defun openai-chat--buffer-change-hook (beg end length)
  "Check for a role prefix in lines affected by the edit and apply color if found."
  ;; Extend `end` if a newline was inserted.
  (when (and (> (- end beg) length)
             (save-excursion
               (goto-char beg)
               (looking-at-p "\n")))
    (save-excursion
      (goto-char end)
      (end-of-line)
      (setq end (point))))
  (openai-chat--debug "openai-chat--buffer-change-hook called: beg=%d, end=%d, length=%d" beg end length)
  (save-excursion
    (goto-char beg)
    (beginning-of-line)
    (let (line-beg line-end role)
      (while (progn
               (setq line-beg (point))
               (forward-line)
               (setq line-end (point))
               (let ((line (buffer-substring-no-properties line-beg line-end)))
                 (openai-chat--debug "Affected line: %s" line)
                 (openai-chat--color-line line-beg))
               (< (point) end))))))

(defun openai-chat--color-line (position)
  "Colors the line starting from POSITION based on the role prefix."
  (save-excursion
    (goto-char position)
    (beginning-of-line)
    (let ((line-beg (point))
          (line-end (line-end-position)))
      ;; First, remove existing face properties from the line
      (remove-text-properties line-beg line-end '(face nil))
      ;; Then, apply new face properties based on the role prefix
      (let ((line (buffer-substring-no-properties line-beg line-end)))
        (if (string-match "\\`\\([^ ]+\\): " line)
            (let ((first-word (match-string 1 line))
                  role face)
              (when (member first-word '("system" "user" "assistant"))
                (setq role first-word)
                (setq face (cond
                            ((string= role "system") 'openai-chat--system-face)
                            ((string= role "assistant") 'openai-chat--assistant-face)
                            ((string= role "user") 'openai-chat--user-face))))
              (when face
                (put-text-property line-beg (+ line-beg (length first-word)) 'face face))))))))

(defun openai-chat--get-headers (api-key)
  "Format and return the HTTP headers."
  `(("Authorization" . ,(format "Bearer %s" api-key))
    ("Content-Type"  . "application/json")))

(defun openai-chat--compose-data (model)
 "Format and return the HTTP data."
 `(("model" . ,model)
   ("messages" . ,(openai-chat--parse-buffer-to-json))))

(defun openai-chat-send ()
  "Sends the user's input to OpenAI's chat API."
  (interactive)
  (let* ((current-buffer openai-chat--buffer)
         (api-key (openai-chat--load-api-key))
         (headers (openai-chat--get-headers api-key))
         (data (openai-chat--compose-data openai-chat-model)))
    (message "Sending request")
    (openai-chat--debug "request data: %s" (json-encode data))
    (request
     openai-chat-api-endpoint
     :type "POST"
     :headers headers
     :data (json-encode data)
     :parser 'json-read
     :success (cl-function
               (lambda (&key data &allow-other-keys)
                 (when data
                   (message "Reply received")
                   (openai-chat--debug "reply data: %s" (json-encode data))
                   (with-current-buffer current-buffer
                     (let* ((choices (cdr (assoc 'choices data)))
                            (message (cdr (assoc 'message (aref choices 0))))
                            (role (cdr (assoc 'role message)))
                            (content (cdr (assoc 'content message))))
                       (goto-char (point-max))
                       (insert (format "\n%s: %s\nuser: " role content)))))))
     :error (cl-function
             (lambda (&key error-thrown &allow-other-keys&rest _)
               (message "Got error: %S" error-thrown))))))

(defun openai-chat--load-api-key ()
  "Loads the OpenAI API key from a file."
  (let ((key-file (expand-file-name "~/.openai/apikey")))
    (if (file-exists-p key-file)
        (with-temp-buffer
          (insert-file-contents key-file)
          (buffer-string))
      (error "API key file not found. Please create a file at '~/.openai/apikey' with the API key"))))

(defun openai-chat--load-model ()
  "Loads the OpenAI Model from a file or uses the default model if no file exists."
  (let ((model-file (expand-file-name "~/.openai/model")))
    (if (file-exists-p model-file)
        (with-temp-buffer
          (insert-file-contents model-file)
          (buffer-string))
      openai-chat-model)))

(defun openai-chat--load-api-endpoint ()
  "Loads the OpenAI API endpoint from a file or uses the default endpoint if no file exists."
  (let ((endpoint-file (expand-file-name "~/.openai/endpoint")))
    (if (file-exists-p endpoint-file)
        (with-temp-buffer
          (insert-file-contents endpoint-file)
          (buffer-string))
      openai-chat-api-endpoint)))

(defun openai-chat-set-model (model)
  "Set the model for the chat."
  (interactive "sEnter model: ")
  (setq openai-chat-model model)
  (force-mode-line-update))

(defun openai-chat-set-api-endpoint (endpoint)
  "Set the API endpoint for the chat."
  (interactive "sEnter API endpoint: ")
  (setq openai-chat-api-endpoint endpoint)
  (force-mode-line-update))

(defun openai-chat--remove-trailing-newlines (str)
  "Remove trailing newlines from STR."
  (while (string-match "\n\\'" str)
    (setq str (replace-match "" t t str)))
  str)

(defun openai-chat--parse-buffer-to-json ()
  "Parse the buffer into a JSON message structure that handles all messages."
  (save-excursion
    (goto-char (point-min))
    (let ((role-line-regexp "\\(system\\|user\\|assistant\\): \\(.*\\)")
          (messages '())
          (content "")
          (role ""))
      (while (re-search-forward role-line-regexp nil t)
        (if (not (string= role ""))
            (progn
              (add-to-list 'messages `(("role" . ,role) ("content" . ,(openai-chat--remove-trailing-newlines content))) t)
              (setq content "")))
        (setq role (match-string 1))
        (setq content (concat content (match-string 2)))
        (let ((next-role-pos (save-excursion
                               (if (re-search-forward role-line-regexp nil t)
                                   (match-beginning 0)
                                 (point-max)))))
          (forward-line 1)
          (while (< (point) next-role-pos)
            (setq content (concat content "\n" (buffer-substring-no-properties (point) (line-end-position))))
            (forward-line 1))))
      (add-to-list 'messages `(("role" . ,role) ("content" . ,(openai-chat--remove-trailing-newlines content))) t)
      messages)))
