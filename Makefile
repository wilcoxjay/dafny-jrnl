DFY_FILES := $(shell find src -path src/Dafny/examples/bank-go -prune -false -o -name "*.dfy")
OK_FILES := $(DFY_FILES:.dfy=.dfy.ok)

DAFNY_ARGS := /compile:0 /compileTarget:go /nologo /compileVerbose:0
DAFNY := ./etc/dafnyq $(DAFNY_ARGS)

Q:=@

default: $(OK_FILES)

compile: src/Dafny/examples/bank-go/src/bank.go

all: $(OK_FILES) compile

.dafnydeps.d: $(DFY_FILES) etc/dafnydep
	@echo "DAFNYDEP"
	$(Q)./etc/dafnydep $(DFY_FILES) > $@

# do not try to build dependencies if cleaning
ifeq ($(filter clean,$(MAKECMDGOALS)),)
-include .dafnydeps.d
endif

%.dfy.ok: %.dfy
	@echo "DAFNY $<"
	$(Q)$(DAFNY) /compile:0 "$<" 1>/dev/null
	$(Q)touch "$@"

src/Dafny/examples/bank-go/src/bank.go: src/Dafny/examples/bank.dfy $(DFY_FILES)
	@echo "DAFNY COMPILE $<"
	$(Q)$(DAFNY) /countVerificationErrors:0 /spillTargetCode:2 $< 1>/dev/null

clean:
	@echo "CLEAN"
	$(Q)find . -name "*.dfy.ok" -delete
	$(Q)rm -f .dafnydeps.d
	$(Q)rm -rf src/Dafny/examples/bank-go
