import ArgumentParser

func notImplemented(_ milestone: String) -> ExitCode {
    Term.err("not implemented yet (milestone \(milestone))")
    return ExitCode(1)
}
