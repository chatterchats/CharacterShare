-- Character Share: logging.
-- Initialized once per mod instance; shared references use explicit ctx fields.
-- Context: config, logging.
return function(ctx)
    function ctx.logging.log(message)
        print(string.format("%s %s\n", ctx.config.MOD_TAG, tostring(message)))
    end
end
