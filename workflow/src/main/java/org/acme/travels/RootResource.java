package org.acme.travels;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.OPTIONS;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

@Path("/")
public class RootResource {

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Response root() {
        return Response.ok("{\"runtime\":\"process-usertasks-quarkus\",\"status\":\"up\"}").build();
    }

    @OPTIONS
    public Response options() {
        return Response.ok().build();
    }
}
