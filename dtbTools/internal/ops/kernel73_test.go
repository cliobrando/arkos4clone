package ops

import (
	"os"
	"path/filepath"
	"testing"

	"arkos4clone/dtbtools/internal/i18n"
)

// The 7.3 boot.ini and DTB replace the console's, like 7.1's.
func TestCopyConsoleFiles73(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	for p, s := range map[string]string{
		"boot.ini": "ini44", "a.dtb": "dtb44",
		"7.1/boot.ini": "ini71", "7.1/a.dtb": "dtb71",
		"7.3/boot.ini": "ini73", "7.3/a.dtb": "dtb73",
	} {
		f := filepath.Join(src, p)
		if err := os.MkdirAll(filepath.Dir(f), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(s), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := copyConsoleFiles(src, dst, Kernel73); err != nil {
		t.Fatal(err)
	}
	for n, want := range map[string]string{"boot.ini": "ini73", "a.dtb": "dtb73"} {
		got, err := os.ReadFile(filepath.Join(dst, n))
		if err != nil || string(got) != want {
			t.Errorf("%s = %q, %v, want %q", n, got, err, want)
		}
	}
	for _, d := range []string{"7.1", "7.3"} {
		if _, err := os.Stat(filepath.Join(dst, d)); err == nil {
			t.Errorf("folder %s was copied", d)
		}
	}
}

// An F2FS root boots only on 7.3: chosen without asking, refused without it.
func TestSelectKernelF2FSRoot(t *testing.T) {
	lang := &i18n.English
	k, err := SelectKernel(lang, true, true, true)
	if err != nil || k != Kernel73 {
		t.Errorf("with 7.3: got %q, %v, want %q", k, err, Kernel73)
	}
	if _, err := SelectKernel(lang, true, false, true); err == nil {
		t.Error("without 7.3: no error")
	}
}
