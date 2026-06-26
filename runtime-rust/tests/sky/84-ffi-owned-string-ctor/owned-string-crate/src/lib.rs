// 84-ffi-owned-string-ctor: owned-`String` constructor-arg proof fixture.
//
// This is the LAST firestore residual (#67): a foreign ctor taking an OWNED
// `String` param — exactly `FirestoreDbOptions::new(project_id: String)` — was
// miscompiled to `Opts::new(&arg0)` (passing `&String`) where the host wants an
// owned `String` → E0308. The codegen's argCall mapped every Sky `String` param
// to a borrowed `&base`, the INVERSE of #60 (which added `.as_ref()` for
// genuinely-borrowed `&str`/`&Path` params).
//
// Fix: argCall now branches on the host param's OWNED-vs-BORROWED Rust type
// (carried by the inspector as `rust_type` — "String" owned vs "&str" borrowed).
//   • owned `String` host param → pass by value (`Opts::new(arg0)`).
//   • `&str`/`&String` host param → keep the borrowed pass (`&arg` / `.as_ref()`).

pub struct Opts {
    project: String,
    label: String,
}

impl Opts {
    /// OWNED `String` ctor — the firestore `FirestoreDbOptions::new` shape.
    /// MUST compile to `Opts::new(arg0)` (by value), NOT `Opts::new(&arg0)`.
    pub fn new(project: String) -> Opts {
        Opts {
            project,
            label: String::new(),
        }
    }

    /// Getter so the Sky side can verify the owned value threaded through.
    pub fn project(&self) -> String {
        self.project.clone()
    }

    /// CONTROL: a borrowed `&str` builder — proves the #60 borrowed path STILL
    /// works (no-regress). MUST keep the `.as_ref()` / `&arg` borrowed pass.
    pub fn with_label(self, label: &str) -> Opts {
        Opts {
            project: self.project,
            label: label.to_string(),
        }
    }

    /// Read the label back (proves with_label threaded its borrowed arg).
    pub fn label(&self) -> String {
        self.label.clone()
    }
}
