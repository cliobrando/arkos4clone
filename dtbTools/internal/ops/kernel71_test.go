package ops

import (
	"os"
	"path/filepath"
	"testing"
)

// The 7.1 boot.ini and DTB replace the console's, and the kernel folders stay out.
func TestCopyConsoleFiles71(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	write := func(p, s string) {
		t.Helper()
		f := filepath.Join(src, p)
		if err := os.MkdirAll(filepath.Dir(f), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(s), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write("boot.ini", "ini44")
	write("a.dtb", "dtb44")
	write("6.1/a.dtb", "dtb61")
	write("7.1/a.dtb", "dtb71")
	write("7.1/boot.ini", "ini71")

	check := func(kernel, ini, dtb string) {
		t.Helper()
		if err := copyConsoleFiles(src, dst, kernel); err != nil {
			t.Fatal(err)
		}
		for n, want := range map[string]string{"boot.ini": ini, "a.dtb": dtb} {
			got, err := os.ReadFile(filepath.Join(dst, n))
			if err != nil || string(got) != want {
				t.Errorf("%s %s = %q, %v, want %q", kernel, n, got, err, want)
			}
		}
		for _, d := range []string{"6.1", "7.1"} {
			if _, err := os.Stat(filepath.Join(dst, d)); err == nil {
				t.Errorf("%s: folder %s was copied", kernel, d)
			}
		}
	}
	check(Kernel71, "ini71", "dtb71")
	check(Kernel61, "ini44", "dtb61")
	check(Kernel44, "ini44", "dtb44")
}
