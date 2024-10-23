global _start

section .bss
    buffer resb 65535                   ; Buffer for the maximum segment
    lookup_table resq 256               ; Buffer for lookup table
    len_buf resb 2                      ; Buffer for segment length
    current_pos resq 1                  ; Buffer for the current file position
    segment_jump resd 1                 ; Buffer for the segment jump
    output_buffer resb 65               ; Buffer for output

section .data
    shift db 0                          ; Buffer for shift amount

section .text

; Entry point of the program
; Check if the correct number of arguments is passed
; Initialize CRC storage
_start:
    mov rsi, [rsp]                      ; Load the number of arguments
    cmp rsi, 3
    jne .error_exit
    xor r8, r8                          ; Initialize CRC storage

; Load CRC polynomial from command line argument
; Store it in r10 and calculate the shift amount
.load_crc_poly:
    mov rdi, [rsp+24]                   ; Load the pointer to the polynomial str
    mov rcx, 64                         ; Set polynomial shift (64 - length)
    xor r10, r10                        ; Initialize polynomial storage

.load_crc_poly_loop:
    mov r11b, byte [rdi]                ; Load byte from polynomial string
    test r11b, r11b                     ; Check if byte is zero
    jz .load_crc_poly_end

    cmp r11b, '0'                       ; Check if byte is '0'
    je .load_crc_poly_loop_is_zero

    cmp r11b, '1'                       ; Check if byte is '1'
    je .load_crc_poly_loop_is_one

    jmp .error_exit                     ; If not '0' or '1', exit with error

.load_crc_poly_loop_is_zero:
    shl r10, 1                          ; Shift polynomial left by 1
    jmp .load_crc_poly_loop_next_sign

.load_crc_poly_loop_is_one:
    shl r10, 1                          ; Shift polynomial left by 1
    or r10, 1                           ; OR polynomial with 1
    jmp .load_crc_poly_loop_next_sign

.load_crc_poly_loop_next_sign:
    inc rdi                             ; Increment string pointer
    dec cl                              ; Decrement shift counter
    cmp cl, 0                           ; Check if shift counter is zero
    jl .error_exit                      ; If less than zero, exit with error
    jmp .load_crc_poly_loop

.load_crc_poly_end:
    cmp rcx, 64                         ; Check if shift counter is 64
    je .error_exit                      ; If equal, exit with error
    mov [shift], cl                     ; Store shift amount
    shl r10, cl                         ; Shift polynomial to most sign. bits

; Generate the lookup table for CRC calculation
.lookup_table_generator:
    xor r9, r9                          ; Initialize lookup table value storage
    xor r11, r11                        ; Initialize lookup table index
    lea rdi, lookup_table               ; Load pointer to lookup table

.lookup_table_generator_loop:
    mov r9, r11                         ; Copy index to value storage
    shl r9, 56                          ; Shift value left by 56

    xor rax, rax                        ; Clear rax

.lookup_table_generator_loop_single:
    shl r9, 1                           ; Shift value left by 1
    jnc .lookup_table_generator_loop_single_end
    xor r9, r10                         ; XOR value with polynomial

.lookup_table_generator_loop_single_end:
    inc rax                             ; Increment counter
    cmp rax, 8                          ; Check if counter is 8
    jnge .lookup_table_generator_loop_single

    mov [rdi + 8 * r11], r9             ; Store value in lookup table
    inc r11                             ; Increment index
    cmp r11, 256                        ; Check if index is 256
    jnge .lookup_table_generator_loop

; Load the file specified in the command line arguments
.load_file:
    mov rax, 2                          ; syscall: sys_open
    mov rdi, [rsp+16]                   ; Load file name
    xor rsi, rsi                        ; mode: O_RDONLY
    syscall
    test rax, rax
    js .error_exit                      ; If error, exit
    mov r9, rax                         ; Store file descriptor

; Save the current file pointer position
.read_file_pointer_position_save:
    mov rax, 8                          ; syscall: sys_lseek
    mov rdi, r9                         ; File descriptor
    xor rsi, rsi                        ; Offset
    mov rdx, 1                          ; Whence: SEEK_CUR
    syscall
    test rax, rax
    js .error_exit_with_close
    mov [current_pos], rax              ; Store current position

; Read the length of the next segment from the file
.read_file_segment_length:
    mov rax, 0                          ; syscall: sys_read
    mov rdi, r9                         ; File descriptor
    mov rsi, len_buf                    ; Buffer for length
    mov rdx, 2                          ; Read 2 bytes
    syscall
    test rax, rax
    js .error_exit_with_close
    cmp rax, 2
    jne .error_exit_with_close

; Read the segment from the file into the buffer
.read_file_hole_segment:
    mov rax, 0                          ; syscall: sys_read
    mov rdi, r9                         ; File descriptor
    mov rsi, buffer                     ; Buffer for segment
    movzx rdx, word [len_buf]           ; Segment length
    syscall
    test rax, rax
    js .error_exit_with_close

; Calculate the CRC for the current segment
.calculate_crc:
    lea rax, buffer                     ; Load buffer address
    lea rdi, lookup_table               ; Load lookup table address
    xor r11, r11                        ; Initialize segment position
    movzx rdx, word [len_buf]           ; Load segment length
    cmp rdx, 0                          ; Check if segment length is zero
    je .check_for_next_segment

.calculate_crc_loop:
    movzx rsi, byte [rax + r11]         ; Load byte from segment
    shl rsi, 56                         ; Shift byte left by 56
    xor rsi, r8                         ; XOR with current CRC
    shr rsi, 56                         ; Shift byte right by 56
    shl r8, 8                           ; Shift CRC left by 8
    xor r8, [rdi + 8 * rsi]             ; XOR with lookup table value

    inc r11                             ; Increment segment position
    cmp r11, rdx                        ; Check if end of segment
    jl .calculate_crc_loop

; Load jump length
.check_for_next_segment:
    mov rax, 0                          ; syscall: sys_read
    mov rdi, r9                         ; File descriptor
    mov rsi, segment_jump               ; Buffer for segment jump
    mov rdx, 4                          ; Read 4 bytes
    syscall
    test rax, rax
    js .error_exit_with_close
    cmp rax, 4
    jne .error_exit_with_close

; Check if we have reached the end of the file
.check_if_end:
    movsxd rsi, dword [segment_jump]    ; Load segment jump
    mov rax, 8                          ; syscall: sys_lseek
    mov rdi, r9                         ; File descriptor
    mov rdx, 1                          ; Whence: SEEK_CUR
    syscall
    test rax, rax
    js .error_exit_with_close

    cmp rax, [current_pos]              ; Compare with current position
    jne .read_file_pointer_position_save

; Finalize the CRC calculation and print the result
.done:
    xor rcx, rcx
    mov cl, [shift]                     ; Load shift amount
    shr r8, cl                          ; Shift CRC right by shift amount
    mov r10, 64
    sub r10, rcx                        ; Subtract shift amount from 64

.print_r8_bin:
    mov rsi, output_buffer + 64         ; Load output buffer end
    mov rcx, r10                        ; Load shift amount

.convert_loop:
    dec rsi                             ; Decrement output buffer pointer
    mov rdx, r8                         ; Load CRC
    and rdx, 1                          ; Get least significant bit
    add dl, '0'                         ; Convert to ASCII
    mov [rsi], dl                       ; Store in output buffer
    shr r8, 1                           ; Shift CRC right by 1
    loop .convert_loop

    mov byte [output_buffer + 64], 10   ; Newline at end of buffer
    add r10, 1

    mov rdx, r10                        ; Number of bytes to write
    mov rax, 1                          ; syscall: sys_write
    mov rdi, 1                          ; File descriptor: stdout
    mov rsi, rsi                        ; Output buffer
    syscall

    ; Close the file
    mov rdi, r9                         ; File descriptor
    mov rax, 3                          ; syscall: sys_close
    syscall

    ; Exit the program
    mov rax, 60                         ; syscall: sys_exit
    xor rdi, rdi                        ; Exit code 0
    syscall

; Error handling: exit the program with an error code
.error_exit:
    mov rax, 60                         ; syscall: sys_exit
    mov rdi, 1                          ; Exit code 1
    syscall

; Error handling: close the file and exit the program with an error code
.error_exit_with_close:
    mov rdi, r9                         ; File descriptor
    mov rax, 3                          ; syscall: sys_close
    syscall

    mov rax, 60                         ; syscall: sys_exit
    mov rdi, 1                          ; Exit code 1
    syscall
