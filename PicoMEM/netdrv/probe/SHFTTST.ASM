; Runs the exact 186 test from Crynwr TAIL.ASM and reports it.
; Prints "is_186=1" if the CPU masks the shift count (driver uses REP INSW),
; "is_186=0" if not (driver uses the byte-at-a-time loop). rc = is_186.
	org 100h
	mov	cl,33
	mov	ax,0ffffh
	shl	ax,cl
	mov	bl,0
	jz	done
	mov	bl,1
done:	mov	al,bl
	add	al,'0'
	mov	[digit],al
	mov	dx,msg
	mov	ah,9
	int	21h
	mov	al,bl
	mov	ah,4ch
	int	21h
msg	db	'is_186='
digit	db	'?',13,10,'$'
