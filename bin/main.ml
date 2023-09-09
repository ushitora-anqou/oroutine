[@@@warning "-69"]

let debug_print fmt =
  Printf.ksprintf
    (fun s ->
      print_endline s;
      flush stdout)
    fmt

let rec fib n = if n <= 1 then n else fib (n - 1) + fib (n - 2)

module type S = sig
  type task = unit -> unit

  val go : task -> unit
end

module Oroutine : S = struct
  type task = unit -> unit
  type processor = { dom : unit Domain.t }
  type run_queue = { v : task Queue.t; mtx : Mutex.t; cond : Condition.t }
  type env = { processors : processor array; q : run_queue }

  let worker (q : run_queue) () =
    let rec loop should_lock =
      if should_lock then Mutex.lock q.mtx;
      if Queue.is_empty q.v then (
        Condition.wait q.cond q.mtx;
        loop false)
      else
        let task = Queue.pop q.v in
        Mutex.unlock q.mtx;
        (try task () with _ -> ());
        loop true
    in
    loop true

  let spawn env f =
    Mutex.lock env.q.mtx;
    Queue.push f env.q.v;
    Condition.signal env.q.cond;
    Mutex.unlock env.q.mtx

  let make_env () =
    let q =
      { v = Queue.create (); mtx = Mutex.create (); cond = Condition.create () }
    in
    {
      q;
      processors =
        Array.init (Domain.recommended_domain_count ()) (fun _ ->
            { dom = Domain.spawn (worker q) });
    }

  let global_env = make_env ()
  let go f = spawn global_env f
end

let () =
  for i = 0 to 100 do
    Oroutine.(
      go (fun () ->
          debug_print "done %d %d" i (fib 40);
          ()))
  done;
  debug_print "waiting";
  Unix.sleep 10;
  debug_print "timeout";
  ()
