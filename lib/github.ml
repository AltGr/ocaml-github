(*
 * Copyright (c) 2012 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

(* Authorization Scopes *)
module Scope = struct

  let string_of_scope (x:Github_t.scope) =
    match x with
    | `User -> "user"
    | `Public_repo -> "public_repo"
    | `Repo -> "repo"
    | `Gist -> "gist"
    | `Repo_status -> "repo_status"
    | `Delete_repo -> "delete_repo"

  let scope_of_string x : Github_t.scope option =
    match x with
    | "user" -> Some `User
    | "public_repo" -> Some `Public_repo
    | "repo" -> Some `Repo
    | "gist" -> Some `Gist
    | "repo_status" -> Some `Repo_status
    | "delete_repo" -> Some `Delete_repo
    | _ -> None

  let string_of_scopes scopes =
    String.concat "," (List.map string_of_scope scopes)

  let scopes_of_string s =
    let scopes = Re_str.(split (regexp_string ",") s) in
    List.fold_left (fun a b ->
      match scope_of_string b with
      | None -> a
      | Some b -> b::a
    ) [] scopes

  let all = [ `User; `Public_repo; `Repo; `Gist; `Repo_status; `Delete_repo ]
end

module URI = struct
  let authorize ?scopes ?redirect_uri ~client_id () =
    let entry_uri = "https://github.com/login/oauth/authorize" in
    let uri = Uri.of_string entry_uri in
    let q = ["client_id", client_id ] in
    let q = match scopes with
     |Some scopes -> ("scope", Scope.string_of_scopes scopes) :: q
     |None -> q in
    let q = match redirect_uri with
     |Some uri -> ("redirect_uri", Uri.to_string uri) :: q 
     |None -> q in
    Uri.with_query' uri q

  let token ~client_id ~client_secret ~code () =
    let uri = Uri.of_string "https://github.com/login/oauth/access_token" in
    let q = [ "client_id", client_id; "code", code; "client_secret", client_secret ] in
    Uri.with_query' uri q

  let api = "https://api.github.com"

  let authorizations =
    Uri.of_string (Printf.sprintf "%s/authorizations" api)

  let authorization ~id =
    Uri.of_string (Printf.sprintf "%s/authorizations/%d" api id)

  let user ?login () =
    match login with
    |None -> Uri.of_string (Printf.sprintf "%s/user" api)
    |Some u -> Uri.of_string (Printf.sprintf "%s/users/%s" api u)

  let repo ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s" api user repo) 

  let repo_issues ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/issues" api user repo) 

  let repo_issue ~user ~repo ~issue_number =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/issues/%d" api user repo issue_number) 

  let repo_tags ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/tags" api user repo)

  let repo_tag ~user ~repo ~sha =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/git/tags/%s" api user repo sha)

  let repo_refs ?ty ~user ~repo =
    let suffix =
      match ty with
      |None -> ""
      |Some ty -> "/"^ty
    in
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/git/refs%s" api user repo suffix)

  let repo_commit ~user ~repo ~sha =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/commits/%s" api user repo sha)

  let repo_hooks ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/hooks" api user repo)

  let hook ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/hooks/%d" api user repo num)

  let hook_test ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/hooks/%d/tests" api user repo num)

  let repo_pulls ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls" api user repo)

  let pull ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls/%d" api user repo num)

  let pull_commits ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls/%d/commits" api user repo num)

  let pull_files ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls/%d/files" api user repo num)

  let pull_merge ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls/%d/merge" api user repo num)

  let repo_milestones ~user ~repo =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/milestones" api user repo)

  let milestone ~user ~repo ~num =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/milestones/%d" api user repo num)

  let issue_comments ~user ~repo ~issue_number =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/issues/%d/comments" api user repo issue_number)

  let issue_comment ~user ~repo ~comment_id =
    Uri.of_string (Printf.sprintf "%s/repos/%s/%s/issues/comments/%d" api user repo comment_id)

end 

module C = Cohttp
module CL = Cohttp_lwt_unix
module CLB = CL.Body
open Lwt

module Monad = struct
  open Printf

  (* Each API call results in either a valid response or
   * an HTTP error. Depending on the error status code, it may
   * be retried within the monad, or a permanent failure returned *)
  type error =
  | Generic of CL.Response.t
  | Semantic of Github_t.message
  | No_response
  | Bad_response of exn
  and 'a response =
  | Error of error
  | Response of 'a
  and 'a t = 'a response Lwt.t

  let error_to_string = function
    | Generic res ->
      sprintf "HTTP Error %s\n%s\n" (C.Code.string_of_status (CL.Response.status res))
        (String.concat "\n" (C.Header.to_lines (CL.Response.headers res)))
    | Semantic message ->
      sprintf "GitHub Error %s\n%s"
        message.Github_t.message_message
        (List.fold_left (fun s {Github_t.error_resource; error_field; error_code} ->
          let error_field = match error_field with None -> "\"\"" | Some x -> x in
          sprintf "%s> Resource type: %s\n  Field: %s\n  Code: %s\n"
            s error_resource error_field error_code)
           "" message.Github_t.message_errors)
    | No_response -> "No response"
    | Bad_response exn -> sprintf "Bad response: %s\n" (Printexc.to_string exn)    

  let bind x fn =
    match_lwt x with
    |Error e -> return (Error e)
    |Response r -> fn r

  let return r =
    return (Response r)

  let run th =
    match_lwt th with
    |Response r -> Lwt.return r
    |Error e -> fail (Failure (error_to_string e))

  let (>>=) = bind
end

module API = struct
  open Lwt

  (* Use the highest precedence handler that matches the response. *)
  let rec handle_response response = function
    | (p, handler)::more -> if p response then begin
      try_lwt
        lwt r = CLB.string_of_body (snd response) >>= handler in
        return (Monad.Response r)
      with exn -> return (Monad.(Error (Bad_response exn)))
      end else handle_response response more
    | [] ->
        let envelope, message = response in
        if CL.Response.status envelope = `Unprocessable_entity
        then lwt body = CLB.string_of_body message in
             return (Monad.(Error (Semantic (Github_j.message_of_string body))))
        else return (Monad.(Error (Generic envelope)))

  (* Add an authorization token onto a request URI and parse the response
   * as JSON. *)
  let request_with_token ?headers ?token ?(params=[]) uri reqfn resp_handlers =
    let uri = Uri.add_query_params' uri params in
    (* Add the correct mime-type header *)
    let headers = match headers with
     |Some x -> Some (C.Header.add x "content-type" "application/json")
     |None -> Some (C.Header.of_list ["content-type","application/json"]) in
    let uri = match token with
     |Some token -> Uri.add_query_param uri ("access_token", [token]) 
     |None -> uri in
    Printf.eprintf "%s\n%!" (Uri.to_string uri);
    match_lwt (reqfn ?headers) uri with
    |None ->
      return (Monad.(Error No_response))
    |Some response -> begin
      Printf.eprintf "Github response code %s\n%!"
        (C.Code.string_of_status (CL.Response.status (fst response)));
      handle_response response resp_handlers
    end

  (* Convert a request body into a stream and force chunked-encoding
   * to be disabled (to satisfy Github, which returns 411 Length Required
   * to a chunked-encoding POST request). *)
  let request_with_token_body ?headers ?token ?body uri req resp_handlers =
    let body = match body with
      |None -> None |Some b -> CLB.body_of_string b in
    let chunked = Some false in
    request_with_token ?headers ?token uri (req ?body ?chunked) resp_handlers

  let code_handler ~expected_code handler =
    (fun (res,_) -> CL.Response.status res = expected_code), handler

  let get ?headers ?token ?(params=[]) ?(expected_code=`OK) ~uri fn =
    request_with_token ?headers ?token ~params uri CL.Client.get
      [code_handler ~expected_code fn]

  let post ?headers ?body ?token ~expected_code ~uri fn =
    request_with_token_body ?headers ?token ?body uri CL.Client.post
      [code_handler ~expected_code fn]

  let patch ?headers ?body ?token ~expected_code ~uri fn =
    request_with_token_body ?headers ?token ?body uri CL.Client.patch
      [code_handler ~expected_code fn]

  let put ?headers ?body ?token ~expected_code ~uri fn =
    request_with_token_body ?headers ?token ?body uri CL.Client.put
      [code_handler ~expected_code fn]

  let delete ?headers ?token ?(params=[]) ?(expected_code=`No_content) ~uri fn =
    request_with_token ?headers ?token ~params uri CL.Client.delete
      [code_handler ~expected_code fn]
end

open Github_t
open Github_j
open Lwt

module Token = struct
  type t = string

  let create ?(scopes=[`Repo]) ?note ?note_url ?client_id ?client_secret ~user ~pass () =
    let req = { auth_req_scopes=scopes; auth_req_note=note; auth_req_note_url=note_url;
     auth_req_client_id=client_id; auth_req_client_secret=client_secret } in
    let body = string_of_auth_req req in
    let headers = C.Header.(add_authorization (init ()) (C.Auth.Basic (user,pass))) in
    let uri = URI.authorizations in
    API.post ~headers ~body ~uri ~expected_code:`Created (fun body -> return (auth_of_string body))

  let get_all ~user ~pass () =
    let uri = URI.authorizations in
    let headers = C.Header.(add_authorization (init ()) (C.Auth.Basic (user,pass))) in
    API.get ~headers ~uri ~expected_code:`OK (fun body -> return (auths_of_string body))

  let get ~user ~pass ~id () =
    let uri = URI.authorization id in
    let headers = C.Header.(add_authorization (init ()) (C.Auth.Basic (user,pass))) in
    API.get ~headers ~uri ~expected_code:`OK (fun body -> return (auth_of_string body))

  (* Convert a code after a user oAuth into an access token that can
   * be used in subsequent requests.
   *)
  let of_code ~client_id ~client_secret ~code () =
    let uri = URI.token ~client_id ~client_secret ~code () in
    match_lwt CL.Client.post uri with
    |None -> return None
    |Some (res, body) -> begin
      lwt body = CLB.string_of_body body in
      try
        let form = Uri.query_of_encoded body in
        return (Some (List.(hd (assoc "access_token" form))))
      with _ ->
        return None
    end

  let of_auth x = x.auth_token
  let of_string x = x
  let to_string x = x
end

module User = struct
  let current_info ~token () =
    let uri = URI.user () in
    API.get ~token ~uri (fun body -> return (user_info_of_string body))

  let info ?token ~login () =
    let uri = URI.user ~login () in
    API.get ?token ~uri (fun body -> return (user_info_of_string body))
end

module Filter = struct
  type state = [ `Open | `Closed ]
  let string_of_state (s:state) =
    match s with
    |`Open -> "open"
    |`Closed -> "closed"
  
  type milestone_sort = [ `Due_date | `Completeness ]
  let string_of_sort (s:milestone_sort) =
    match s with
    |`Due_date -> "due_date"
    |`Completeness -> "completeness"

  type issue_sort = [ `Created | `Updated | `Comments ]
  let string_of_issue_sort (s:issue_sort) =
    match s with
    |`Created -> "created"
    |`Updated -> "updated"
    |`Comments -> "comments"

  type direction = [ `Asc | `Desc ]
  let string_of_direction (d:direction) =
    match d with
    |`Asc -> "asc"
    |`Desc -> "desc"

  type milestone = [ `Any | `None | `Num of int ]
  let string_of_milestone (m:milestone) =
    match m with 
    |`Any -> "*"
    |`None -> "none"
    |`Num n -> string_of_int n 

  type user = [ `Any | `None | `Login of string ]
  let string_of_user (a:user) =
    match a with
    |`Any -> "*"
    |`None -> "none"
    |`Login u -> u
end

module Pull = struct

  let for_repo ?(state=`Open) ?token ~user ~repo () =
    let params = Filter.([
      "state", string_of_state state ]) in
    API.get ?token ~params ~uri:(URI.repo_pulls ~user ~repo)
      (fun b -> return (pulls_of_string b))

  let get ?token ~user ~repo ~num () =
    let uri = URI.pull ~user ~repo ~num in
    API.get ?token ~uri (fun b -> return (pull_of_string b))

  let create ?token ~user ~repo ~pull () =
    let uri = URI.repo_pulls ~user ~repo in
    let body = string_of_new_pull pull in
    API.post ?token ~body ~uri ~expected_code:`Created (fun b -> return (pull_of_string b))

  let create_from_issue ?token ~user ~repo ~pull_issue () =
    let uri = URI.repo_pulls ~user ~repo in
    let body = string_of_new_pull_issue pull_issue in
    API.post ?token ~body ~uri ~expected_code:`Created (fun b -> return (pull_of_string b))

  let update ?token ~user ~repo ~update_pull ~num () =
    let uri = URI.pull ~user ~repo ~num in
    let body = string_of_update_pull update_pull in
    API.patch ?token ~body ~uri ~expected_code:`OK (fun b -> return (pull_of_string b))

  let list_commits ?token ~user ~repo ~num () =
    let uri = URI.pull_commits ~user ~repo ~num in
    API.get ?token ~uri (fun b -> return (commits_of_string b))

  let list_files ?token ~user ~repo ~num () =
    let uri = URI.pull_files ~user ~repo ~num in
    API.get ?token ~uri (fun b -> return (files_of_string b))

  let is_merged ?token ~user ~repo ~num () =
    let uri = URI.pull_merge ~user ~repo ~num in
    API.(request_with_token ?token uri CL.Client.get [
      code_handler ~expected_code:`No_content (fun _ -> return true);
      code_handler ~expected_code:`Not_found  (fun _ -> return false);
    ])

  let merge ?token ~user ~repo ~num ?merge_commit_message () =
    let uri = URI.pull_merge ~user ~repo ~num in
    let body = string_of_merge_request {merge_commit_message} in
    API.put ?token ~body ~uri ~expected_code:`OK (fun b -> return (merge_of_string b))

end

module Milestone = struct

  let for_repo ?(state=`Open) ?(sort=`Due_date) ?(direction=`Desc) ?token ~user ~repo () =
    let params = Filter.([
      "direction", string_of_direction direction;
      "sort", string_of_milestone_sort sort;
      "state", string_of_state state ]) in
    API.get ?token ~params ~uri:(URI.repo_milestones ~user ~repo) 
      (fun b -> return (milestones_of_string b))

  let get ?token ~user ~repo ~num () =
    let uri = URI.milestone ~user ~repo ~num in
    API.get ?token ~uri (fun b -> return (milestone_of_string b))

  let delete ?token ~user ~repo ~num () =
    let uri = URI.milestone ~user ~repo ~num in
    API.delete ?token ~uri (fun _ -> return ())

  let create ?token ~user ~repo ~milestone () =
    let uri = URI.repo_milestones ~user ~repo in
    let body = string_of_new_milestone milestone in
    API.post ?token ~body ~uri ~expected_code:`Created (fun b -> return (milestone_of_string b))

  let update ?token ~user ~repo ~milestone ~num () =
    let uri = URI.milestone ~user ~repo ~num in
    let body = string_of_update_milestone milestone in
    API.patch ?token ~body ~uri ~expected_code:`OK (fun b -> return (milestone_of_string b))
end

module Issue = struct
  
  let for_repo ?token ?creator ?mentioned ?labels
    ?(milestone=`Any) ?(state=`Open) ?(sort=`Created)
    ?(direction=`Desc) ?assignee ~user ~repo () =
    let params = Filter.([
      "direction", string_of_direction direction;
      "sort", string_of_issue_sort sort;
      "state", string_of_state state;
      "milestone", string_of_milestone milestone ]) in
    let params = match assignee with |None -> params |Some a -> ("assignee", Filter.string_of_user a)::params in
    let params = match creator with |None -> params |Some c -> ("creator", c)::params in
    let params = match mentioned with |None -> params |Some m -> ("mentioned", m)::params in
    let params = match labels with |None -> params |Some l -> ("labels",String.concat "," l)::params in
    let uri = URI.repo_issues ~user ~repo in
    API.get ?token ~params ~uri (fun b -> return (issues_of_string b))

  let create ?token ~user ~repo ~issue () =
    let body = string_of_new_issue issue in
    let uri = URI.repo_issues ~user ~repo in
    API.post ~body ?token ~uri ~expected_code:`Created (fun b -> return (issue_of_string b))

  let update ?token ~user ~repo ~issue_number ~issue () =
    let body = string_of_new_issue issue in
    let uri = URI.repo_issue ~user ~repo ~issue_number in
    API.patch ~body ?token ~uri ~expected_code:`OK (fun b -> return (issue_of_string b))

  let comments ?token ~user ~repo ~issue_number () =
    let uri = URI.issue_comments ~user ~repo ~issue_number in
    API.get ?token ~uri (fun b -> return (issue_comments_of_string b))

  let create_comment ?token ~user ~repo ~issue_number ~body () =
    let body = string_of_new_issue_comment { new_issue_comment_body=body } in
    let uri = URI.issue_comments ~user ~repo ~issue_number in
    API.post ~body ?token ~uri ~expected_code:`Created (fun b -> return (issue_comment_of_string b))
end

module Repo = struct

  let info ?token ~user ~repo () =
    let uri = URI.repo ~user ~repo in
    API.get ?token ~uri (fun b -> return (repo_of_string b))

  let tags ?token ~user ~repo () =
    let uri = URI.repo_tags ~user ~repo in
    API.get ?token ~uri (fun b -> return (repo_tags_of_string b))

  let refs ?token ?ty ~user ~repo () =
    let uri = URI.repo_refs ?ty ~user ~repo in
    API.get ?token ~uri (fun b -> return (git_refs_of_string b))

  let commit ?token ~user ~repo ~sha () =
    let uri = URI.repo_commit ~user ~repo ~sha in
    API.get ?token ~uri (fun b -> return (commit_of_string b))

  let hooks ?token ~user ~repo () =
    let uri = URI.repo_hooks ~user ~repo in
    API.get ?token ~uri (fun b -> return (hooks_of_string b))

  let hook ?token ~user ~repo ~num () =
    let uri = URI.hook ~user ~repo ~num in
    API.get ?token ~uri (fun b -> return (hook_of_string b))

  let create_hook ?token ~user ~repo ~hook () =
    let uri = URI.repo_hooks ~user ~repo in
    let body = string_of_new_hook hook in
    API.post ~body ?token ~uri ~expected_code:`Created (fun b -> return (hook_of_string b))

  let update_hook ?token ~user ~repo ~num ~hook () =
    let uri = URI.hook ~user ~repo ~num in
    let body = string_of_update_hook hook in
    API.patch ?token ~body ~uri ~expected_code:`OK (fun b -> return (hook_of_string b))

  let delete_hook ?token ~user ~repo ~num () =
    let uri = URI.hook ~user ~repo ~num in
    API.delete ?token ~uri (fun _ -> return ())

  let test_hook ?token ~user ~repo ~num () =
    let uri = URI.hook_test ~user ~repo ~num in
    API.post ?token ~uri ~expected_code:`No_content (fun b -> return ())
end

module Git_obj = struct

  let obj_type_to_string (o:obj_type)=
    match o with
    |`Tree -> "tree"
    |`Commit -> "commit"
    |`Blob -> "blob"
    |`Tag -> "tag"

  let split_ref =
    let re = Re_str.regexp_string "/" in
    fun ref ->
      match Re_str.bounded_split re ref 3 with
      |[_;ty;tl] -> ty, tl
      |_ -> "", ref
end

module Tag = struct

  let tag ?token ~user ~repo ~sha () =
    let uri = URI.repo_tag ~user ~repo ~sha in
    API.get ?token ~uri (fun b -> return (tag_of_string b))

  (* Retrieve a list of SHA hashes for tags, and obtain a
   * name and time for each tag.  If annotated, this is explicit,
   * and otherwise it uses the last commit *)
  let get_tags_and_times ?token ~user ~repo () =
    let open Monad in
    Repo.refs ?token ~ty:"tags" ~user ~repo () >>=
    fun tags ->
      let rec aux acc = function
        | [] -> return acc
        | hd :: tl -> begin
            let _,name = Git_obj.split_ref hd.git_ref_name in
            let sha = hd.git_ref_obj.obj_sha in
            match hd.git_ref_obj.obj_ty with
            |`Commit -> (* lightweight tag, so get commit info *)
               Repo.commit ?token ~user ~repo ~sha () >>=
               fun c ->
                 let acc = (name, c.commit_git.git_commit_author.info_date) :: acc in
                 aux acc tl
            |`Tag ->
               tag ?token ~user ~repo ~sha () >>=
               fun t ->
                 let acc = (name, t.tag_tagger.info_date) :: acc in
                 aux acc tl
            |_ -> aux acc tl
        end
      in aux [] tags
end

