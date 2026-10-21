import Lean

/-!
# The axiom check

sangaku runs this file with `lean --run` after a problem's module compiled, in a sandbox and a folder of its own:

    lean --run AxiomCheck.lean <module.olean> <imports> <declaration>...

It reads the compiled module as data, checks that it imports exactly `<imports>` (comma-separated module names), and
replays every declaration the module adds through Lean's kernel on top of those imports. It then prints one JSON line
per declaration asked about: its kind in the replayed environment and, for a theorem, the axioms it depends on.

None of the module's own code runs here. Its elaborators, attributes and messages do not reach this process, and a
declaration the kernel rejects stops the check with exit status 1.
-/

open Lean

/-- The kind of a declaration in the replayed environment. -/
def kindName : Option ConstantInfo → String
  | some (.thmInfo _) => "theorem"
  | some _ => "other"
  | none => "missing"

unsafe def check (olean : System.FilePath) (expected : Array Name) (declarations : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)
  let parts ← readModuleDataParts #[olean]
  let some (module, _) := parts[0]? | throw <| IO.userError "the compiled module could not be read"
  if module.isModule then
    throw <| IO.userError "the compiled module is a module-system file, which sangaku never writes"
  -- Every module imports `Init` implicitly; the rest must be exactly what the app wrote.
  let imports := module.imports.map (·.module) |>.filter (· != `Init)
  unless imports == expected do
    throw <| IO.userError s!"the compiled module imports {imports}, not {expected}"
  let (_, state) ← importModulesCore module.imports |>.run
  let base ← finalizeImport state module.imports {} 0 false false (isModule := true)
  let mut added : Std.HashMap Name ConstantInfo := {}
  for name in module.constNames, info in module.constants do
    added := added.insert name info
  let kernel ← base.toKernelEnv.replay added
  let replayed := Environment.ofKernelEnv kernel
  for declaration in declarations do
    let name := declaration.toName
    let kind := kindName (kernel.find? name)
    let axioms ← if kind == "theorem" then
        (collectAxioms name : CoreM (Array Name)).run' { fileName := "AxiomCheck", fileMap := default } { env := replayed }
          |>.toIO fun _ => IO.userError s!"the axioms of {declaration} could not be collected"
      else pure #[]
    IO.println <| Json.compress <| Json.mkObj [
      ("declaration", Json.str declaration),
      ("kind", Json.str kind),
      ("axioms", Json.arr (axioms.map (Json.str ·.toString)))]
  return 0

unsafe def main (args : List String) : IO UInt32 := do
  match args with
  | olean :: imports :: declarations =>
    let expected := (imports.splitOn ",").filter (!·.isEmpty) |>.map String.toName |>.toArray
    try
      check olean expected declarations
    catch error =>
      IO.eprintln s!"axiom check: {error}"
      return 1
  | _ =>
    IO.eprintln "usage: lean --run AxiomCheck.lean <module.olean> <imports> <declaration>..."
    return 2
