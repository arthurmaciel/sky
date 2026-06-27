#![allow(dead_code)]
//! 105-ffi-generic-struct-accessor: #73 Part A (E0107). A field accessor for a
//! GENERIC struct emits the BARE struct name (`Gen` not `Gen<T>`) for the receiver
//! → E0107 "missing generics" (surfaced firestore SKY_DCE=0, `FirestoreWithMetadata<T>`).
//! Fix: the inspector fail-closed DROPS field accessors for any struct with a
//! type/const generic param. Non-generic struct accessors are UNAFFECTED.

/// Non-generic struct — its pub-field accessors MUST still bind.
pub struct Plain {
    pub x: i64,
}
impl Plain {
    pub fn new(x: i64) -> Plain { Plain { x } }
}

/// Generic struct — its pub-field accessors MUST be DROPPED (else E0107).
pub struct Gen<T> {
    pub val: T,
    pub tag: i64,
}
impl Gen<i64> {
    pub fn make_i64() -> Gen<i64> { Gen { val: 7, tag: 1 } }
}
