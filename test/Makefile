.phony: test neovim-test clean

test:
	./run_vim_tests ${TEST}

neovim-test:
	./run_neovim_tests

clean:
	rm -f *.log
	rm -f *.res
	rm -f debuglog
	rm -f messages
	rm -f Xtest*
	rm -f .coverage.*
	rm -f .vim_profile
	rm -rf logs/
